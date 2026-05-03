const std = @import("std");
const vk = @import("c");
const ctx_mod = @import("context.zig");
const cmd_mod = @import("command.zig");
const molten = @import("../molten.zig");
const Context = ctx_mod.Context;
const CommandBuffer = cmd_mod.CommandBuffer;

pub const BindEntry = struct {
    ctx: *const Context,
    handle: vk.VkBuffer,
    size: vk.VkDeviceSize,
};

pub const DispatchOptions = struct {
    groups: [3]u32,
    push: []const u8 = &.{},
};

pub const PipelineOptions = struct {
    binding_count: u32,
    push_constant_size: u32 = 0,
    /// How many in-flight dispatches this pipeline can support against
    /// distinct descriptor sets. record() rotates through the ring;
    /// exceeding it returns error.RingExhausted. 0 means use the comptime
    /// default from molten.options.
    descriptor_ring_size: u32 = 0,
};

const MAX_BINDINGS: u32 = molten.options.max_bindings;
const MAX_PUSH_CONSTANT_SIZE: u32 = molten.options.max_push_constant_size;
const DEFAULT_RING: u32 = molten.options.default_descriptor_ring_size;
const MAX_RING: u32 = molten.options.max_descriptor_ring_size;

pub const Pipeline = struct {
    ctx: *Context,
    shader: vk.VkShaderModule,
    ds_layout: vk.VkDescriptorSetLayout,
    pl_layout: vk.VkPipelineLayout,
    pipeline: vk.VkPipeline,
    pool: vk.VkDescriptorPool,
    sets: [MAX_RING]vk.VkDescriptorSet,
    binding_count: u32,
    push_constant_size: u32,
    ring_size: u32,
    ring_cursor: u32,
    in_flight: u32,

    pub fn init(ctx: *Context, spv_bytes: []const u8, options: PipelineOptions) !Pipeline {
        if (spv_bytes.len % 4 != 0 or spv_bytes.len < 4) return error.BadShader;
        if (options.binding_count == 0) return error.InvalidArgument;
        if (options.binding_count > MAX_BINDINGS) return error.TooManyBindings;
        if (options.push_constant_size > MAX_PUSH_CONSTANT_SIZE) return error.PushConstantTooLarge;
        if (options.push_constant_size % 4 != 0) return error.InvalidArgument;
        const ring_size = if (options.descriptor_ring_size == 0) DEFAULT_RING else options.descriptor_ring_size;
        if (ring_size == 0) return error.InvalidArgument;
        if (ring_size > MAX_RING) return error.RingSizeTooLarge;
        const binding_count = options.binding_count;
        const push_size = options.push_constant_size;

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
        try ctx_mod.check(ctx.diag, vk.vkCreateShaderModule(ctx.device, &shader_info, null, &shader), "vkCreateShaderModule");
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
            ctx.diag,
            vk.vkCreateDescriptorSetLayout(ctx.device, &ds_layout_info, null, &ds_layout),
            "vkCreateDescriptorSetLayout",
        );
        errdefer vk.vkDestroyDescriptorSetLayout(ctx.device, ds_layout, null);

        const push_range: vk.VkPushConstantRange = .{
            .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT,
            .offset = 0,
            .size = push_size,
        };
        const pl_layout_info: vk.VkPipelineLayoutCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1,
            .pSetLayouts = &ds_layout,
            .pushConstantRangeCount = if (push_size > 0) 1 else 0,
            .pPushConstantRanges = if (push_size > 0) &push_range else null,
        };
        var pl_layout: vk.VkPipelineLayout = undefined;
        try ctx_mod.check(
            ctx.diag,
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
            ctx.diag,
            vk.vkCreateComputePipelines(ctx.device, null, 1, &pipeline_info, null, &pipeline),
            "vkCreateComputePipelines",
        );
        errdefer vk.vkDestroyPipeline(ctx.device, pipeline, null);

        // One pool sized for the whole ring, allocated once. record()
        // rewrites set contents via vkUpdateDescriptorSets without ever
        // touching the pool again.
        const pool_size: vk.VkDescriptorPoolSize = .{
            .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = binding_count * ring_size,
        };
        const pool_info: vk.VkDescriptorPoolCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = ring_size,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        };
        var pool: vk.VkDescriptorPool = undefined;
        try ctx_mod.check(ctx.diag, vk.vkCreateDescriptorPool(ctx.device, &pool_info, null, &pool), "vkCreateDescriptorPool");
        errdefer vk.vkDestroyDescriptorPool(ctx.device, pool, null);

        var ring_layouts: [MAX_RING]vk.VkDescriptorSetLayout = undefined;
        for (0..ring_size) |i| ring_layouts[i] = ds_layout;
        const ds_alloc_info: vk.VkDescriptorSetAllocateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = pool,
            .descriptorSetCount = ring_size,
            .pSetLayouts = &ring_layouts,
        };
        var sets: [MAX_RING]vk.VkDescriptorSet = undefined;
        try ctx_mod.check(ctx.diag, vk.vkAllocateDescriptorSets(ctx.device, &ds_alloc_info, &sets), "vkAllocateDescriptorSets");

        return .{
            .ctx = ctx,
            .shader = shader,
            .ds_layout = ds_layout,
            .pl_layout = pl_layout,
            .pipeline = pipeline,
            .pool = pool,
            .sets = sets,
            .binding_count = binding_count,
            .push_constant_size = push_size,
            .ring_size = ring_size,
            .ring_cursor = 0,
            .in_flight = 0,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        // Sets are freed implicitly with the pool.
        vk.vkDestroyDescriptorPool(self.ctx.device, self.pool, null);
        vk.vkDestroyPipeline(self.ctx.device, self.pipeline, null);
        vk.vkDestroyPipelineLayout(self.ctx.device, self.pl_layout, null);
        vk.vkDestroyDescriptorSetLayout(self.ctx.device, self.ds_layout, null);
        vk.vkDestroyShaderModule(self.ctx.device, self.shader, null);
        self.* = undefined;
    }

    /// Caller must call this only once *all* in-flight dispatches against
    /// this pipeline have completed on the device (e.g. after a fence
    /// covering every outstanding submit, or vkQueueWaitIdle). Resetting
    /// while any slot is still in use will let record() hand that slot
    /// out again and the GPU will read/write through it under the prior
    /// submission. Resets the cursor so the ring restarts at slot 0.
    pub fn ringReset(self: *Pipeline) void {
        self.in_flight = 0;
        self.ring_cursor = 0;
    }

    /// Records bind/push/dispatch into `cmd`. Caller is responsible for
    /// having called cmd.begin(), and for inserting any barriers and
    /// calling cmd.end() / Context.submit() afterwards. Each call consumes
    /// one ring slot; the slot becomes reusable after ringReset() (i.e.
    /// once the caller knows the prior submission completed).
    ///
    /// Barrier rules:
    /// - Reading a written buffer back on the host: insert
    ///   cmd.barrierComputeToHost() before cmd.end().
    /// - Feeding the output of one dispatch into another on the GPU:
    ///   insert cmd.barrierComputeToCompute() between the two record()
    ///   calls (same cmd) or at the start of the second cmd.
    /// Without these the read sees stale data; validation layers will
    /// flag it but releases will silently misbehave.
    pub fn record(self: *Pipeline, cmd: *CommandBuffer, binds: []const BindEntry, options: DispatchOptions) !void {
        if (binds.len != self.binding_count) return error.InvalidArgument;
        if (options.push.len != self.push_constant_size) return error.InvalidArgument;
        if (self.in_flight >= self.ring_size) return error.RingExhausted;
        const ctx = self.ctx;
        std.debug.assert(cmd.ctx == ctx);
        for (binds) |b| std.debug.assert(b.ctx == ctx);

        const slot = self.ring_cursor;
        self.ring_cursor = (self.ring_cursor + 1) % self.ring_size;
        self.in_flight += 1;
        const ds = self.sets[slot];

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

        vk.vkCmdBindPipeline(cmd.handle, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
        vk.vkCmdBindDescriptorSets(cmd.handle, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pl_layout, 0, 1, &ds, 0, null);
        if (options.push.len > 0) {
            vk.vkCmdPushConstants(
                cmd.handle,
                self.pl_layout,
                vk.VK_SHADER_STAGE_COMPUTE_BIT,
                0,
                @intCast(options.push.len),
                options.push.ptr,
            );
        }
        vk.vkCmdDispatch(cmd.handle, options.groups[0], options.groups[1], options.groups[2]);
    }

    /// One-shot helper: records into a temporary command buffer, adds a
    /// compute->host barrier (the common case for "read the result back
    /// from the CPU"), submits, and waits idle. For chained GPU work or
    /// host/device overlap, use record() + Context.submit() directly.
    pub fn dispatch(self: *Pipeline, binds: []const BindEntry, options: DispatchOptions) !void {
        var cmd = try CommandBuffer.init(self.ctx);
        defer cmd.deinit();

        try cmd.begin();
        try self.record(&cmd, binds, options);
        cmd.barrierComputeToHost();
        try cmd.end();

        try self.ctx.submit(.{ .cmd = &cmd });
        try ctx_mod.check(self.ctx.diag, vk.vkQueueWaitIdle(self.ctx.queue), "vkQueueWaitIdle");
        self.ringReset();
    }
};
