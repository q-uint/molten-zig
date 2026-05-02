const gpu = @import("std").gpu;

const Buf = extern struct { data: [1]u32 };

const buf = gpu.storageBuffer(Buf, 0, 0, "buf");

var scratch: [1]u32 addrspace(.shared) = undefined;

pub const Kernel = struct {
    pub fn entry() callconv(.spirv_kernel) void {
        gpu.executionMode(entry, .{ .local_size = .{ .x = 1, .y = 1, .z = 1 } });

        scratch[0] = buf.*.data[0];

        gpu.controlBarrier(.workgroup, .workgroup, .{
            .acquire_release = true,
            .workgroup_memory = true,
        });

        gpu.memoryBarrier(.workgroup, .{
            .acquire_release = true,
            .workgroup_memory = true,
        });

        buf.*.data[0] = scratch[0];
    }
};

comptime {
    @export(&Kernel.entry, .{ .name = "main" });
}
