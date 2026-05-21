// Usage: ./vector_multiply <kernel.spv> [--bench]

const std = @import("std");
const common = @import("common");

const N: u32 = 1024;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    const args = try common.Args.parse(init, alloc);
    defer args.deinit(alloc);
    const want_bench = args.rest.len > 0 and std.mem.eql(u8, args.rest[0], "--bench");

    var input: [N]f32 = undefined;
    var expected: [N]f32 = undefined;
    for (0..N) |i| {
        input[i] = @floatFromInt(i);
        expected[i] = input[i] * 2.0;
    }

    var session = try common.Session.open(init, alloc, args.spv_path);
    defer session.deinit();

    try session.verifyTwoBuffer(f32, .{
        .input = &input,
        .expected = &expected,
        .groups = .{ N, 1, 1 },
        .label = "vector_multiply",
    });

    if (!want_bench) return;

    var in = try session.ctx.createBuffer(f32, N);
    defer in.deinit();
    var out = try session.ctx.createBuffer(f32, N);
    defer out.deinit();
    try in.write(&input);

    var pipeline = try session.ctx.loadPipeline(session.spv, .{ .binding_count = 2 });
    defer pipeline.deinit();

    var label_buf: [64]u8 = undefined;
    _ = try session.runBench(.{
        .label = common.benchLabel(&label_buf, "vector_multiply", args.spv_path, null),
        .pipeline = &pipeline,
        .bindings = &.{ in.bind(), out.bind() },
        .groups = .{ N, 1, 1 },
        .warmup = 8,
        .samples = 64,
        .work = .{ .bytes = @as(u64, N) * @sizeOf(f32) * 2 },
    });
}
