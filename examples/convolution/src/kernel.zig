// 3x3 box-sum convolution over an NxN f32 image, edges clamped. Integer
// kernel weights keep results bit-exact so the harness can compare ==.
// LocalSize 1 1 1; host dispatches (N, N, 1).

const gpu = @import("gpu");

const N = 64;
const Buf = extern struct { data: [N * N]f32 };

const in_buf = gpu.storageBuffer(Buf, 0, 0, "in_buf");
const out_buf = gpu.storageBuffer(Buf, 0, 1, "out_buf");

fn at(x: i32, y: i32) f32 {
    const cx: u32 = @intCast(@max(0, @min(N - 1, x)));
    const cy: u32 = @intCast(@max(0, @min(N - 1, y)));
    return in_buf.*.data[cy * N + cx];
}

export fn main() callconv(.{ .spirv_kernel = .{ .x = 1, .y = 1, .z = 1 } }) void {
    const gx = gpu.global_invocation_id[0];
    const gy = gpu.global_invocation_id[1];
    if (gx >= N or gy >= N) return;

    const x: i32 = @intCast(gx);
    const y: i32 = @intCast(gy);
    var sum: f32 = 0;
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            sum += at(x + dx, y + dy);
        }
    }
    out_buf.*.data[gy * N + gx] = sum;
}
