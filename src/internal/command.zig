const std = @import("std");
const vk = @import("c");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

pub const PipelineStageFlags = vk.VkPipelineStageFlags;

pub const PipelineStage = struct {
    pub const top_of_pipe: PipelineStageFlags = vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
    pub const compute_shader: PipelineStageFlags = vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
    pub const transfer: PipelineStageFlags = vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
    pub const host: PipelineStageFlags = vk.VK_PIPELINE_STAGE_HOST_BIT;
    pub const all_commands: PipelineStageFlags = vk.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
};

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

    /// Required before host-mapped reads of buffers written by a dispatch.
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

/// Signal values must strictly increase across submits on the same Timeline.
pub const Timeline = struct {
    ctx: *Context,
    handle: vk.VkSemaphore,

    pub fn init(ctx: *Context, initial_value: u64) !Timeline {
        const type_info: vk.VkSemaphoreTypeCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
            .semaphoreType = vk.VK_SEMAPHORE_TYPE_TIMELINE,
            .initialValue = initial_value,
        };
        const info: vk.VkSemaphoreCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = &type_info,
        };
        var handle: vk.VkSemaphore = undefined;
        try ctx_mod.check(ctx.diag, vk.vkCreateSemaphore(ctx.device, &info, null, &handle), "vkCreateSemaphore");
        return .{ .ctx = ctx, .handle = handle };
    }

    pub fn deinit(self: *Timeline) void {
        vk.vkDestroySemaphore(self.ctx.device, self.handle, null);
        self.* = undefined;
    }

    pub fn getValue(self: *Timeline) !u64 {
        var value: u64 = 0;
        try ctx_mod.check(
            self.ctx.diag,
            vk.vkGetSemaphoreCounterValue(self.ctx.device, self.handle, &value),
            "vkGetSemaphoreCounterValue",
        );
        return value;
    }

    pub fn wait(self: *Timeline, value: u64, timeout_ns: u64) !void {
        const info: vk.VkSemaphoreWaitInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
            .semaphoreCount = 1,
            .pSemaphores = &self.handle,
            .pValues = &value,
        };
        try ctx_mod.check(
            self.ctx.diag,
            vk.vkWaitSemaphores(self.ctx.device, &info, timeout_ns),
            "vkWaitSemaphores",
        );
    }

    pub fn signal(self: *Timeline, value: u64) !void {
        const info: vk.VkSemaphoreSignalInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO,
            .semaphore = self.handle,
            .value = value,
        };
        try ctx_mod.check(self.ctx.diag, vk.vkSignalSemaphore(self.ctx.device, &info), "vkSignalSemaphore");
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
        try ctx_mod.check(
            self.ctx.diag,
            vk.vkWaitForFences(self.ctx.device, 1, &self.handle, vk.VK_TRUE, timeout_ns),
            "vkWaitForFences",
        );
    }

    pub fn reset(self: *Fence) !void {
        try ctx_mod.check(self.ctx.diag, vk.vkResetFences(self.ctx.device, 1, &self.handle), "vkResetFences");
    }
};

/// Command pool + fence + fixed-capacity command-buffer slab. Compose `[N]FramePool`
/// into a ring for async use.
pub const FramePool = struct {
    pub const Options = struct {
        /// Number of primary command buffers pre-allocated in the pool.
        capacity: u32 = 1,
    };

    ctx: *Context,
    pool: vk.VkCommandPool,
    fence: Fence,
    buffers: []vk.VkCommandBuffer,

    pub fn init(ctx: *Context, options: Options) !FramePool {
        std.debug.assert(options.capacity > 0);

        const info: vk.VkCommandPoolCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .queueFamilyIndex = ctx.queue_family,
        };
        var pool: vk.VkCommandPool = undefined;
        try ctx_mod.check(ctx.diag, vk.vkCreateCommandPool(ctx.device, &info, null, &pool), "vkCreateCommandPool");
        errdefer vk.vkDestroyCommandPool(ctx.device, pool, null);

        const buffers = try ctx.allocator.alloc(vk.VkCommandBuffer, options.capacity);
        errdefer ctx.allocator.free(buffers);

        const alloc_info: vk.VkCommandBufferAllocateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = options.capacity,
        };
        try ctx_mod.check(
            ctx.diag,
            vk.vkAllocateCommandBuffers(ctx.device, &alloc_info, buffers.ptr),
            "vkAllocateCommandBuffers",
        );

        // Pre-signalled so the first waitAndReset() on a fresh ring is a no-op.
        const fence_info: vk.VkFenceCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
        };
        var fh: vk.VkFence = undefined;
        try ctx_mod.check(ctx.diag, vk.vkCreateFence(ctx.device, &fence_info, null, &fh), "vkCreateFence");
        errdefer vk.vkDestroyFence(ctx.device, fh, null);

        return .{
            .ctx = ctx,
            .pool = pool,
            .fence = .{ .ctx = ctx, .handle = fh },
            .buffers = buffers,
        };
    }

    pub fn deinit(self: *FramePool) void {
        // Pool destruction frees the contained command buffers.
        vk.vkDestroyCommandPool(self.ctx.device, self.pool, null);
        vk.vkDestroyFence(self.ctx.device, self.fence.handle, null);
        self.ctx.allocator.free(self.buffers);
        self.* = undefined;
    }

    pub fn capacity(self: *const FramePool) u32 {
        return @intCast(self.buffers.len);
    }

    /// Wait on the fence, reset it, and recycle every command buffer in the pool.
    pub fn waitAndReset(self: *FramePool, timeout_ns: u64) !void {
        try self.fence.wait(timeout_ns);
        try self.fence.reset();
        try ctx_mod.check(
            self.ctx.diag,
            vk.vkResetCommandPool(self.ctx.device, self.pool, 0),
            "vkResetCommandPool",
        );
    }

    /// Borrow the i-th pre-allocated command buffer. Valid until the next
    /// waitAndReset(); do not call deinit on it.
    pub fn get(self: *FramePool, index: u32) CommandBuffer {
        std.debug.assert(index < self.buffers.len);
        return .{ .ctx = self.ctx, .handle = self.buffers[index] };
    }
};
