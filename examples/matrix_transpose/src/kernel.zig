// NxN f32 matrix transpose. Backend emits LocalSize 1 1 1, so the host
// dispatches (N, N, 1) - one workgroup per output element. The 2D
// dispatch shape is the point of this example, even though the workgroup
// size itself is degenerate.

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

const global_invocation_id = @extern(
    *addrspace(.input) @Vector(3, u32),
    .{ .name = "global_invocation_id" },
);

export fn main() callconv(.spirv_kernel) void {
    const x = global_invocation_id.*[0];
    const y = global_invocation_id.*[1];
    if (x >= N or y >= N) return;
    out_buf.*.data[x * N + y] = in_buf.*.data[y * N + x];
}
