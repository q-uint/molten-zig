// Compile-only smoke test for std.gpu barrier primitives. Not dispatched;
// the build wires it into spirv-val so any breakage in the asm templates
// or operand encoding for OpControlBarrier / OpMemoryBarrier fails the
// build before it can reach a downstream user.

const gpu = @import("std").gpu;

const Buf = extern struct { data: [1]u32 };

const buf = @extern(*addrspace(.storage_buffer) Buf, .{
    .name = "buf",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
});

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
