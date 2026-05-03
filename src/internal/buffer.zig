const std = @import("std");
const vk = @import("c");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const pipeline = @import("pipeline.zig");

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        ctx: *Context,
        handle: vk.VkBuffer,
        memory: vk.VkDeviceMemory,
        count: usize,
        size: vk.VkDeviceSize,

        pub fn init(ctx: *Context, count: usize) !Self {
            const size: vk.VkDeviceSize = @intCast(count * @sizeOf(T));

            const info: vk.VkBufferCreateInfo = .{
                .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                .size = size,
                .usage = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            };
            var handle: vk.VkBuffer = undefined;
            try ctx_mod.check(ctx.diag, vk.vkCreateBuffer(ctx.device, &info, null, &handle), "vkCreateBuffer");
            errdefer vk.vkDestroyBuffer(ctx.device, handle, null);

            var mem_req: vk.VkMemoryRequirements = undefined;
            vk.vkGetBufferMemoryRequirements(ctx.device, handle, &mem_req);

            const mem_type = try ctx_mod.findMemoryType(
                ctx.phys,
                mem_req.memoryTypeBits,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            );

            const alloc_info: vk.VkMemoryAllocateInfo = .{
                .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                .allocationSize = mem_req.size,
                .memoryTypeIndex = mem_type,
            };
            var memory: vk.VkDeviceMemory = undefined;
            try ctx_mod.check(ctx.diag, vk.vkAllocateMemory(ctx.device, &alloc_info, null, &memory), "vkAllocateMemory");
            errdefer vk.vkFreeMemory(ctx.device, memory, null);

            try ctx_mod.check(ctx.diag, vk.vkBindBufferMemory(ctx.device, handle, memory, 0), "vkBindBufferMemory");

            return .{
                .ctx = ctx,
                .handle = handle,
                .memory = memory,
                .count = count,
                .size = size,
            };
        }

        pub fn deinit(self: *Self) void {
            // Spec: bound buffers must be destroyed before their memory is freed.
            vk.vkDestroyBuffer(self.ctx.device, self.handle, null);
            vk.vkFreeMemory(self.ctx.device, self.memory, null);
            self.* = undefined;
        }

        pub fn write(self: *Self, data: []const T) !void {
            if (data.len != self.count) return error.InvalidArgument;
            var ptr: ?*anyopaque = null;
            try ctx_mod.check(
                self.ctx.diag,
                vk.vkMapMemory(self.ctx.device, self.memory, 0, self.size, 0, &ptr),
                "vkMapMemory(write)",
            );
            defer vk.vkUnmapMemory(self.ctx.device, self.memory);
            // vkMapMemory only guarantees minMemoryMapAlignment (>= 64).
            std.debug.assert(@intFromPtr(ptr.?) % @alignOf(T) == 0);
            const dst: [*]T = @ptrCast(@alignCast(ptr.?));
            @memcpy(dst[0..data.len], data);
        }

        pub fn bind(self: *const Self) pipeline.BindEntry {
            return .{ .ctx = self.ctx, .handle = self.handle, .size = self.size };
        }

        pub fn readInto(self: *Self, dst: []T) !void {
            if (dst.len != self.count) return error.InvalidArgument;
            var ptr: ?*anyopaque = null;
            try ctx_mod.check(
                self.ctx.diag,
                vk.vkMapMemory(self.ctx.device, self.memory, 0, self.size, 0, &ptr),
                "vkMapMemory(read)",
            );
            defer vk.vkUnmapMemory(self.ctx.device, self.memory);
            std.debug.assert(@intFromPtr(ptr.?) % @alignOf(T) == 0);
            const src: [*]const T = @ptrCast(@alignCast(ptr.?));
            @memcpy(dst, src[0..self.count]);
        }

        pub fn read(self: *Self, result_allocator: std.mem.Allocator) ![]T {
            const out = try result_allocator.alloc(T, self.count);
            errdefer result_allocator.free(out);
            try self.readInto(out);
            return out;
        }
    };
}
