// Usage: ./convolution <kernel.spv> [zig|glsl] [--bench]
//
// The second arg picks the dispatch shape: the Zig kernel uses LocalSize
// 1 1 1 so we dispatch (N, N, 1); the GLSL kernel uses an 8x8 tile so we
// dispatch (N/TILE, N/TILE, 1).

const std = @import("std");
const common = @import("common");

const N: u32 = 64;
const TILE: u32 = 8;

fn clampIdx(v: i32) usize {
    return @intCast(@max(0, @min(@as(i32, N) - 1, v)));
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    const args = try common.Args.parse(init, alloc);
    defer args.deinit(alloc);
    if (args.rest.len < 1) return error.BadArgs;
    const kind = args.rest[0];
    const want_bench = args.rest.len > 1 and std.mem.eql(u8, args.rest[1], "--bench");

    const groups: [3]u32 = if (std.mem.eql(u8, kind, "zig"))
        .{ N, N, 1 }
    else if (std.mem.eql(u8, kind, "glsl"))
        .{ N / TILE, N / TILE, 1 }
    else
        return error.BadArgs;

    var input: [N * N]f32 = undefined;
    var expected: [N * N]f32 = undefined;
    for (0..N) |y| for (0..N) |x| {
        input[y * N + x] = @floatFromInt(y * N + x);
    };
    for (0..N) |y| for (0..N) |x| {
        var sum: f32 = 0;
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const cy = clampIdx(@as(i32, @intCast(y)) + dy);
                const cx = clampIdx(@as(i32, @intCast(x)) + dx);
                sum += input[cy * N + cx];
            }
        }
        expected[y * N + x] = sum;
    };

    var session = try common.Session.open(init, alloc, args.spv_path);
    defer session.deinit();

    try session.verifyTwoBuffer(f32, .{
        .input = &input,
        .expected = &expected,
        .groups = groups,
        .label = "convolution",
    });

    if (!want_bench) return;

    var in = try session.ctx.createBuffer(f32, input.len);
    defer in.deinit();
    var out = try session.ctx.createBuffer(f32, input.len);
    defer out.deinit();
    try in.write(&input);

    var pipeline = try session.ctx.loadPipeline(session.spv, .{ .binding_count = 2 });
    defer pipeline.deinit();

    var label_buf: [64]u8 = undefined;
    _ = try session.runBench(.{
        .label = common.benchLabel(&label_buf, "convolution", args.spv_path, null),
        .pipeline = &pipeline,
        .bindings = &.{ in.bind(), out.bind() },
        .groups = groups,
        .work = .{ .bytes = @as(u64, N * N) * @sizeOf(f32) * 2 },
    });
}
