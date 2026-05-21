// Usage: ./matrix_transpose <kernel.spv> [zig|glsl] [--bench]
//
// The second arg picks the dispatch shape: the Zig kernel uses LocalSize
// 1 1 1 so we dispatch (N, N, 1); the GLSL kernel uses an 8x8 tile so we
// dispatch (N/TILE, N/TILE, 1).

const std = @import("std");
const common = @import("common");

const N: u32 = 64;
const TILE: u32 = 8;

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
        expected[y * N + x] = input[x * N + y];
    };

    var session = try common.Session.open(init, alloc, args.spv_path);
    defer session.deinit();

    try session.verifyTwoBuffer(f32, .{
        .input = &input,
        .expected = &expected,
        .groups = groups,
        .label = "matrix_transpose",
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
        .label = common.benchLabel(&label_buf, "matrix_transpose", args.spv_path, null),
        .pipeline = &pipeline,
        .bindings = &.{ in.bind(), out.bind() },
        .groups = groups,
        .work = .{ .bytes = @as(u64, N * N) * @sizeOf(f32) * 2 },
    });
}
