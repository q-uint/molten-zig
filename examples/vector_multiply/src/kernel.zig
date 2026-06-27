// Element-wise multiply by 2 over a buffer of f32.

const gpu = @import("gpu");

const N = 1024;
const Buf = extern struct { data: [N]f32 };

const in_buf = gpu.storageBuffer(Buf, 0, 0, "in_buf");
const out_buf = gpu.storageBuffer(Buf, 0, 1, "out_buf");

export fn main() callconv(.{ .spirv_kernel = .{ .x = 1, .y = 1, .z = 1 } }) void {
    const i = gpu.global_invocation_id[0];
    if (i >= N) return;
    out_buf.*.data[i] = in_buf.*.data[i] * 2.0;
}
