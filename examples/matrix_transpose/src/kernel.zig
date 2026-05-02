// NxN f32 matrix transpose. LocalSize 1 1 1; host dispatches (N, N, 1) -
// the 2D dispatch shape is the point of this example.

const gpu = @import("std").gpu;

const N = 64;
const Buf = extern struct { data: [N * N]f32 };

const in_buf = @extern(*addrspace(.storage_buffer) Buf, .{
    .name = "in_buf",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
});
const out_buf = @extern(*addrspace(.storage_buffer) Buf, .{
    .name = "out_buf",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } },
});

export fn main() callconv(.spirv_kernel) void {
    const x = gpu.global_invocation_id[0];
    const y = gpu.global_invocation_id[1];
    if (x >= N or y >= N) return;
    out_buf.*.data[x * N + y] = in_buf.*.data[y * N + x];
}
