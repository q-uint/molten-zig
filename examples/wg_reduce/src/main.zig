// Usage: ./wg_reduce <kernel.spv> <sum|max> [--bench]
//
// Single-workgroup tree reduction. The kernel reduces the entire input
// internally using shared scratch + barriers, so the host just collects
// the one-element result.

const std = @import("std");
const common = @import("common");

const N: u32 = 2048;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    const args = try common.Args.parse(init, alloc);
    defer args.deinit(alloc);
    if (args.rest.len < 1) return error.BadArgs;
    const op_arg = args.rest[0];
    const want_bench = args.rest.len > 1 and std.mem.eql(u8, args.rest[1], "--bench");

    var session = try common.Session.open(init, alloc, args.spv_path);
    defer session.deinit();

    if (std.mem.eql(u8, op_arg, "sum")) {
        try runSum(&session);
    } else if (std.mem.eql(u8, op_arg, "max")) {
        try runMax(&session);
    } else {
        return error.BadArgs;
    }

    if (!want_bench) return;
    if (std.mem.eql(u8, op_arg, "sum")) {
        try benchOne(u32, &session, op_arg);
    } else {
        try benchOne(i32, &session, op_arg);
    }
}

fn benchOne(
    comptime T: type,
    session: *common.Session,
    op_arg: []const u8,
) !void {
    var input: [N]T = undefined;
    for (0..N) |i| input[i] = @intCast(i & 0x7f);

    var in = try session.ctx.createBuffer(T, N);
    defer in.deinit();
    var out = try session.ctx.createBuffer(T, 1);
    defer out.deinit();
    try in.write(&input);

    var pipeline = try session.ctx.loadPipeline(session.spv, .{ .binding_count = 2 });
    defer pipeline.deinit();

    var label_buf: [64]u8 = undefined;
    _ = try session.runBench(.{
        .label = common.benchLabel(&label_buf, "wg_reduce", session.spv_path, op_arg),
        .pipeline = &pipeline,
        .bindings = &.{ in.bind(), out.bind() },
        .groups = .{ 1, 1, 1 },
        .work = .{ .bytes = @as(u64, N) * @sizeOf(T) },
    });
}

fn runSum(session: *common.Session) !void {
    var input: [N]u32 = undefined;
    var expected: u64 = 0;
    for (0..N) |i| {
        input[i] = @intCast(i & 0xff);
        expected += input[i];
    }
    const got = try dispatch(u32, session, &input);
    if (got != expected) {
        std.debug.print("sum mismatch: got {d} want {d}\n", .{ got, expected });
        return error.WrongResult;
    }
    std.debug.print("ok: wg_reduce sum u32 -> {d}\n", .{got});
}

fn runMax(session: *common.Session) !void {
    var input: [N]i32 = undefined;
    var expected: i32 = std.math.minInt(i32);
    for (0..N) |i| {
        const v: i32 = @as(i32, @intCast(i & 0x7f)) - 64;
        input[i] = v;
        expected = @max(expected, v);
    }
    const got = try dispatch(i32, session, &input);
    if (got != expected) {
        std.debug.print("max mismatch: got {d} want {d}\n", .{ got, expected });
        return error.WrongResult;
    }
    std.debug.print("ok: wg_reduce max i32 -> {d}\n", .{got});
}

fn dispatch(
    comptime T: type,
    session: *common.Session,
    input: []const T,
) !T {
    var in = try session.ctx.createBuffer(T, input.len);
    defer in.deinit();
    var out = try session.ctx.createBuffer(T, 1);
    defer out.deinit();

    try in.write(input);

    var pipeline = try session.ctx.loadPipeline(session.spv, .{ .binding_count = 2 });
    defer pipeline.deinit();
    try pipeline.dispatch(&.{ in.bind(), out.bind() }, .{ .groups = .{ 1, 1, 1 } });

    const result = try out.read(session.alloc);
    defer session.alloc.free(result);
    return result[0];
}
