// Element-wise multiply by 2 over a buffer of f32.
// Build: `zig build-obj kernel.zig -target spirv64-vulkan -fno-llvm -fno-lld`.

const gpu = @import("std").gpu;

const N = 1024;
const Buf = extern struct { data: [N]f32 };

const in_buf = @extern(*addrspace(.storage_buffer) Buf, .{
    .name = "in_buf",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
});
const out_buf = @extern(*addrspace(.storage_buffer) Buf, .{
    .name = "out_buf",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } },
});

// LocalSize defaults to 1 1 1; host dispatches N x 1 x 1 to match.
export fn main() callconv(.spirv_kernel) void {
    const i = gpu.global_invocation_id[0];
    if (i >= N) return;
    out_buf.*.data[i] = in_buf.*.data[i] * 2.0;
}
