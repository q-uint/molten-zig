// Usage: ./mandelbrot <kernel.spv> [out.ppm]
//
// Dispatches one invocation per pixel, reads back the RGBA8 buffer, and
// writes a binary (P6) PPM. Open with any image viewer, or on macOS:
//   sips -s format png out.ppm --out out.png

const std = @import("std");
const common = @import("common");

const W: u32 = 1024;
const H: u32 = 1024;
const TILE: u32 = 8;

const View = extern struct {
    cx: f32,
    cy: f32,
    scale: f32,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    const args = try common.Args.parse(init, alloc);
    defer args.deinit(alloc);
    const out_path = if (args.rest.len > 0) args.rest[0] else "mandelbrot.ppm";

    var session = try common.Session.open(init, alloc, args.spv_path);
    defer session.deinit();

    var out = try session.ctx.createBuffer(u32, W * H);
    defer out.deinit();

    var pipeline = try session.ctx.loadPipeline(session.spv, .{
        .binding_count = 1,
        .push_constant_size = @sizeOf(View),
    });
    defer pipeline.deinit();

    const view: View = .{ .cx = -0.75, .cy = 0.0, .scale = 1.25 };
    const groups: [3]u32 = .{ (W + TILE - 1) / TILE, (H + TILE - 1) / TILE, 1 };
    try pipeline.dispatch(&.{out.bind()}, .{
        .groups = groups,
        .push = std.mem.asBytes(&view),
    });

    const px = try out.read(alloc);
    defer alloc.free(px);

    try writePpm(init, alloc, out_path, px);
    std.debug.print("wrote {s} ({d}x{d})\n", .{ out_path, W, H });
}

fn writePpm(init: std.process.Init, alloc: std.mem.Allocator, path: []const u8, px: []const u32) !void {
    const header = try std.fmt.allocPrint(alloc, "P6\n{d} {d}\n255\n", .{ W, H });
    defer alloc.free(header);

    const body = try alloc.alloc(u8, px.len * 3);
    defer alloc.free(body);
    for (px, 0..) |p, i| {
        body[i * 3 + 0] = @truncate(p & 0xff);
        body[i * 3 + 1] = @truncate((p >> 8) & 0xff);
        body[i * 3 + 2] = @truncate((p >> 16) & 0xff);
    }

    var file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
    defer file.close(init.io);
    var w = file.writer(init.io, &.{});
    try w.interface.writeAll(header);
    try w.interface.writeAll(body);
    try w.interface.flush();
}
