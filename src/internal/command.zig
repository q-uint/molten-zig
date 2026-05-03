const std = @import("std");
const vk = @import("c");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

pub const PipelineStageFlags = vk.VkPipelineStageFlags;

/// Re-exports of the Vulkan pipeline stage bits relevant to compute work.
/// Used as the `stage` field of SemaphoreWait so callers do not have to
/// reach into the raw C bindings for a single constant.
pub const PipelineStage = struct {
    pub const top_of_pipe: PipelineStageFlags = vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
    pub const compute_shader: PipelineStageFlags = vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
    pub const transfer: PipelineStageFlags = vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
    pub const host: PipelineStageFlags = vk.VK_PIPELINE_STAGE_HOST_BIT;
    pub const all_commands: PipelineStageFlags = vk.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
};

/// Caller-owned, re-recordable command buffer. Allocated from the
/// context's command pool. Use begin/end to record, reset to clear,
/// and Context.submit to send to the queue. No implicit barriers, the
/// caller decides when work is compute->compute or compute->host.
pub const CommandBuffer = struct {
    ctx: *Context,
    handle: vk.VkCommandBuffer,

    pub fn init(ctx: *Context) !CommandBuffer {
        const alloc_info: vk.VkCommandBufferAllocateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = ctx.cmd_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        var handle: vk.VkCommandBuffer = undefined;
        try ctx_mod.check(
            ctx.diag,
            vk.vkAllocateCommandBuffers(ctx.device, &alloc_info, &handle),
            "vkAllocateCommandBuffers",
        );
        return .{ .ctx = ctx, .handle = handle };
    }

    pub fn deinit(self: *CommandBuffer) void {
        vk.vkFreeCommandBuffers(self.ctx.device, self.ctx.cmd_pool, 1, &self.handle);
        self.* = undefined;
    }

    pub fn begin(self: *CommandBuffer) !void {
        const info: vk.VkCommandBufferBeginInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        };
        try ctx_mod.check(self.ctx.diag, vk.vkBeginCommandBuffer(self.handle, &info), "vkBeginCommandBuffer");
    }

    pub fn end(self: *CommandBuffer) !void {
        try ctx_mod.check(self.ctx.diag, vk.vkEndCommandBuffer(self.handle), "vkEndCommandBuffer");
    }

    pub fn reset(self: *CommandBuffer) !void {
        try ctx_mod.check(
            self.ctx.diag,
            vk.vkResetCommandBuffer(self.handle, 0),
            "vkResetCommandBuffer",
        );
    }

    /// shader-write -> shader-read across compute dispatches.
    pub fn barrierComputeToCompute(self: *CommandBuffer) void {
        const mb: vk.VkMemoryBarrier = .{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
        };
        vk.vkCmdPipelineBarrier(
            self.handle,
            vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0,
            1,
            &mb,
            0,
            null,
            0,
            null,
        );
    }

    /// shader-write -> host-read. Required before host-mapped reads of
    /// buffers written by a dispatch.
    pub fn barrierComputeToHost(self: *CommandBuffer) void {
        const mb: vk.VkMemoryBarrier = .{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_HOST_READ_BIT,
        };
        vk.vkCmdPipelineBarrier(
            self.handle,
            vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            vk.VK_PIPELINE_STAGE_HOST_BIT,
            0,
            1,
            &mb,
            0,
            null,
            0,
            null,
        );
    }
};

/// Binary semaphore. Used to order GPU work between submissions on the
/// same queue, or across queues, without round-tripping the host. A
/// semaphore is signaled by one submit and waited on by another; pair
/// each wait with a pipeline stage at which the wait takes effect.
pub const Semaphore = struct {
    ctx: *Context,
    handle: vk.VkSemaphore,

    pub fn init(ctx: *Context) !Semaphore {
        const info: vk.VkSemaphoreCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };
        var handle: vk.VkSemaphore = undefined;
        try ctx_mod.check(ctx.diag, vk.vkCreateSemaphore(ctx.device, &info, null, &handle), "vkCreateSemaphore");
        return .{ .ctx = ctx, .handle = handle };
    }

    pub fn deinit(self: *Semaphore) void {
        vk.vkDestroySemaphore(self.ctx.device, self.handle, null);
        self.* = undefined;
    }
};

pub const Fence = struct {
    ctx: *Context,
    handle: vk.VkFence,

    pub fn init(ctx: *Context) !Fence {
        const info: vk.VkFenceCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        };
        var handle: vk.VkFence = undefined;
        try ctx_mod.check(ctx.diag, vk.vkCreateFence(ctx.device, &info, null, &handle), "vkCreateFence");
        return .{ .ctx = ctx, .handle = handle };
    }

    pub fn deinit(self: *Fence) void {
        vk.vkDestroyFence(self.ctx.device, self.handle, null);
        self.* = undefined;
    }

    pub fn wait(self: *Fence, timeout_ns: u64) !void {
        const r = vk.vkWaitForFences(self.ctx.device, 1, &self.handle, vk.VK_TRUE, timeout_ns);
        if (r == vk.VK_TIMEOUT) return error.Timeout;
        try ctx_mod.check(self.ctx.diag, r, "vkWaitForFences");
    }

    pub fn reset(self: *Fence) !void {
        try ctx_mod.check(self.ctx.diag, vk.vkResetFences(self.ctx.device, 1, &self.handle), "vkResetFences");
    }
};
