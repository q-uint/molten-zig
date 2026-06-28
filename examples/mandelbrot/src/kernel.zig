// One invocation per pixel: escape-time Mandelbrot, writes packed RGBA8 (one
// u32 per pixel, 0xAABBGGRR little-endian so the host can blit straight to a
// PPM). LocalSize 8 8 1; host dispatches (ceil(W/8), ceil(H/8), 1).

const gpu = @import("gpu");

const W: u32 = 1024;
const H: u32 = 1024;
const MAX_ITER: u32 = 256;

const Out = extern struct { px: [W * H]u32 };

const View = extern struct {
    cx: f32,
    cy: f32,
    scale: f32, // half-height of the viewport in complex units
};

const out_buf = gpu.storageBuffer(Out, 0, 0, "out_buf");
const view = gpu.pushConstant(View, "view");

fn pack(r: u32, g: u32, b: u32) u32 {
    return 0xff000000 | (b << 16) | (g << 8) | r;
}

export fn main() callconv(.{ .spirv_kernel = .{ .x = 8, .y = 8, .z = 1 } }) void {
    const gx = gpu.global_invocation_id[0];
    const gy = gpu.global_invocation_id[1];
    if (gx >= W or gy >= H) return;

    const aspect: f32 = @as(f32, W) / @as(f32, H);
    const u = (@as(f32, @floatFromInt(gx)) / @as(f32, W)) * 2.0 - 1.0;
    const v = (@as(f32, @floatFromInt(gy)) / @as(f32, H)) * 2.0 - 1.0;
    const c_re = view.*.cx + u * view.*.scale * aspect;
    const c_im = view.*.cy + v * view.*.scale;

    var x: f32 = 0;
    var y: f32 = 0;
    var iter: u32 = 0;
    while (iter < MAX_ITER) : (iter += 1) {
        const x2 = x * x;
        const y2 = y * y;
        if (x2 + y2 > 4.0) break;
        const xt = x2 - y2 + c_re;
        y = 2.0 * x * y + c_im;
        x = xt;
    }

    var color: u32 = undefined;
    if (iter >= MAX_ITER) {
        color = pack(0, 0, 0);
    } else {
        // Cheap smooth-ish ramp: map iteration count to an RGB sweep.
        const t = iter * 9;
        const r = (t * 5) & 0xff;
        const g = (t * 3) & 0xff;
        const b = (t * 7 + 40) & 0xff;
        color = pack(r, g, b);
    }
    out_buf.*.px[gy * W + gx] = color;
}
