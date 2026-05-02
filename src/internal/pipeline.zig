const std = @import("std");
const vk = @import("c");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

pub const BindEntry = struct {
    handle: vk.VkBuffer,
    size: vk.VkDeviceSize,
};

pub const DispatchOptions = struct {
    groups: [3]u32,
};

/// Upper bound on storage-buffer bindings per pipeline. Lets dispatch() use
/// stack scratch arrays without an allocator. Bump if a real shader needs more.
pub const MAX_BINDINGS: u32 = 16;

pub const Pipeline = struct {
    ctx: *Context,
    shader: vk.VkShaderModule,
    ds_layout: vk.VkDescriptorSetLayout,
    pl_layout: vk.VkPipelineLayout,
    pipeline: vk.VkPipeline,
    binding_count: u32,

    pub fn init(ctx: *Context, spv_bytes: []const u8, binding_count: u32) !Pipeline {
        if (spv_bytes.len % 4 != 0 or spv_bytes.len < 4) return error.BadShader;
        if (binding_count == 0 or binding_count > MAX_BINDINGS) return error.InvalidArgument;

        // Copy into a u32-aligned buffer. vkCreateShaderModule's pCode requires
        // 4-byte alignment, but @embedFile returns a u8 slice aligned to 1.
        const code = try ctx.allocator.alignedAlloc(u32, .of(u32), spv_bytes.len / 4);
        defer ctx.allocator.free(code);
        @memcpy(std.mem.sliceAsBytes(code), spv_bytes);

        // SPIR-V magic: 0x07230203 little-endian. Catch wrong-file-type early
        // with a readable error rather than a cryptic driver rejection.
        if (code[0] != 0x07230203) return error.BadShader;

        const shader_info: vk.VkShaderModuleCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = spv_bytes.len,
            .pCode = code.ptr,
        };
        var shader: vk.VkShaderModule = undefined;
        try ctx_mod.check(vk.vkCreateShaderModule(ctx.device, &shader_info, null, &shader), "vkCreateShaderModule");
        errdefer vk.vkDestroyShaderModule(ctx.device, shader, null);

        // Descriptor layout: `binding_count` storage buffers in set 0, bindings
        // 0..binding_count-1. Caller is responsible for matching the shader.
        var bindings: [MAX_BINDINGS]vk.VkDescriptorSetLayoutBinding = undefined;
        for (0..binding_count) |i| {
            bindings[i] = .{
                .binding = @intCast(i),
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT,
                .pImmutableSamplers = null,
            };
        }
        const ds_layout_info: vk.VkDescriptorSetLayoutCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = binding_count,
            .pBindings = &bindings,
        };
        var ds_layout: vk.VkDescriptorSetLayout = undefined;
        try ctx_mod.check(
            vk.vkCreateDescriptorSetLayout(ctx.device, &ds_layout_info, null, &ds_layout),
            "vkCreateDescriptorSetLayout",
        );
        errdefer vk.vkDestroyDescriptorSetLayout(ctx.device, ds_layout, null);

        const pl_layout_info: vk.VkPipelineLayoutCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1,
            .pSetLayouts = &ds_layout,
        };
        var pl_layout: vk.VkPipelineLayout = undefined;
        try ctx_mod.check(
            vk.vkCreatePipelineLayout(ctx.device, &pl_layout_info, null, &pl_layout),
            "vkCreatePipelineLayout",
        );
        errdefer vk.vkDestroyPipelineLayout(ctx.device, pl_layout, null);

        const stage_info: vk.VkPipelineShaderStageCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.VK_SHADER_STAGE_COMPUTE_BIT,
            .module = shader,
            .pName = "main",
        };
        const pipeline_info: vk.VkComputePipelineCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .stage = stage_info,
            .layout = pl_layout,
        };
        var pipeline: vk.VkPipeline = undefined;
        try ctx_mod.check(
            vk.vkCreateComputePipelines(ctx.device, null, 1, &pipeline_info, null, &pipeline),
            "vkCreateComputePipelines",
        );
        errdefer vk.vkDestroyPipeline(ctx.device, pipeline, null);

        return .{
            .ctx = ctx,
            .shader = shader,
            .ds_layout = ds_layout,
            .pl_layout = pl_layout,
            .pipeline = pipeline,
            .binding_count = binding_count,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        vk.vkDestroyPipeline(self.ctx.device, self.pipeline, null);
        vk.vkDestroyPipelineLayout(self.ctx.device, self.pl_layout, null);
        vk.vkDestroyDescriptorSetLayout(self.ctx.device, self.ds_layout, null);
        vk.vkDestroyShaderModule(self.ctx.device, self.shader, null);
        self.* = undefined;
    }

    /// Synchronous: records, submits, and waits for queue idle before returning.
    pub fn dispatch(self: *Pipeline, binds: []const BindEntry, options: DispatchOptions) !void {
        if (binds.len != self.binding_count) return error.InvalidArgument;
        const ctx = self.ctx;

        const pool_size: vk.VkDescriptorPoolSize = .{
            .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = @intCast(binds.len),
        };
        const pool_info: vk.VkDescriptorPoolCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = 1,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        };
        var pool: vk.VkDescriptorPool = undefined;
        try ctx_mod.check(vk.vkCreateDescriptorPool(ctx.device, &pool_info, null, &pool), "vkCreateDescriptorPool");
        defer vk.vkDestroyDescriptorPool(ctx.device, pool, null);

        const ds_alloc_info: vk.VkDescriptorSetAllocateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.ds_layout,
        };
        var ds: vk.VkDescriptorSet = undefined;
        try ctx_mod.check(vk.vkAllocateDescriptorSets(ctx.device, &ds_alloc_info, &ds), "vkAllocateDescriptorSets");

        var buf_infos: [MAX_BINDINGS]vk.VkDescriptorBufferInfo = undefined;
        var writes: [MAX_BINDINGS]vk.VkWriteDescriptorSet = undefined;
        for (binds, 0..) |b, i| {
            buf_infos[i] = .{ .buffer = b.handle, .offset = 0, .range = b.size };
            writes[i] = .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = ds,
                .dstBinding = @intCast(i),
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pBufferInfo = &buf_infos[i],
            };
        }
        vk.vkUpdateDescriptorSets(ctx.device, @intCast(binds.len), &writes, 0, null);

        const cmd_alloc_info: vk.VkCommandBufferAllocateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = ctx.cmd_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        var cmd: vk.VkCommandBuffer = undefined;
        try ctx_mod.check(
            vk.vkAllocateCommandBuffers(ctx.device, &cmd_alloc_info, &cmd),
            "vkAllocateCommandBuffers",
        );
        defer vk.vkFreeCommandBuffers(ctx.device, ctx.cmd_pool, 1, &cmd);

        const begin_info: vk.VkCommandBufferBeginInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        try ctx_mod.check(vk.vkBeginCommandBuffer(cmd, &begin_info), "vkBeginCommandBuffer");
        vk.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
        vk.vkCmdBindDescriptorSets(cmd, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pl_layout, 0, 1, &ds, 0, null);
        vk.vkCmdDispatch(cmd, options.groups[0], options.groups[1], options.groups[2]);

        const compute_to_host: vk.VkMemoryBarrier = .{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_HOST_READ_BIT,
        };
        vk.vkCmdPipelineBarrier(
            cmd,
            vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            vk.VK_PIPELINE_STAGE_HOST_BIT,
            0,
            1,
            &compute_to_host,
            0,
            null,
            0,
            null,
        );
        try ctx_mod.check(vk.vkEndCommandBuffer(cmd), "vkEndCommandBuffer");

        const submit_info: vk.VkSubmitInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
        };
        try ctx_mod.check(vk.vkQueueSubmit(ctx.queue, 1, &submit_info, null), "vkQueueSubmit");
        try ctx_mod.check(vk.vkQueueWaitIdle(ctx.queue), "vkQueueWaitIdle");
    }
};
