// Usage: ./reduce <kernel.spv> <sum|max> [--bench]

const std = @import("std");
const common = @import("common");

const WORKGROUP_SIZE: u32 = 64;
const Push = extern struct { n: u32, tile: u32 };

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
        try runSum(&session, 1 << 14, 64);
        try runSum(&session, 1 << 16, 128);
    } else if (std.mem.eql(u8, op_arg, "max")) {
        try runMax(&session, 1 << 14, 64);
        try runMax(&session, 1 << 16, 128);
    } else {
        return error.BadArgs;
    }

    if (!want_bench) return;
    const n: u32 = 1 << 16;
    const tile: u32 = 128;
    const partials: u32 = n / tile;
    if (std.mem.eql(u8, op_arg, "sum")) {
        try benchOne(u32, &session, op_arg, n, tile, partials);
    } else {
        try benchOne(i32, &session, op_arg, n, tile, partials);
    }
}

fn benchOne(
    comptime T: type,
    session: *common.Session,
    op_arg: []const u8,
    n: u32,
    tile: u32,
    partials: u32,
) !void {
    const input = try session.alloc.alloc(T, n);
    defer session.alloc.free(input);
    for (input, 0..) |*p, i| p.* = @intCast(i & 0x7f);

    var in = try session.ctx.createBuffer(T, n);
    defer in.deinit();
    var out = try session.ctx.createBuffer(T, partials);
    defer out.deinit();
    try in.write(input);

    var pipeline = try session.ctx.loadPipeline(session.spv, .{
        .binding_count = 2,
        .push_constant_size = @sizeOf(Push),
    });
    defer pipeline.deinit();

    const push = Push{ .n = n, .tile = tile };
    var label_buf: [64]u8 = undefined;
    _ = try session.runBench(.{
        .label = common.benchLabel(&label_buf, "reduce", session.spv_path, op_arg),
        .pipeline = &pipeline,
        .bindings = &.{ in.bind(), out.bind() },
        .groups = .{ partials / WORKGROUP_SIZE, 1, 1 },
        .push = std.mem.asBytes(&push),
        .work = .{ .bytes = @as(u64, n) * @sizeOf(T) },
    });
}

fn runSum(session: *common.Session, n: u32, tile: u32) !void {
    const input = try session.alloc.alloc(u32, n);
    defer session.alloc.free(input);
    var expected: u64 = 0;
    for (input, 0..) |*p, i| {
        p.* = @intCast(i & 0xff);
        expected += p.*;
    }

    const partials = try dispatch(u32, session, input, tile);
    defer session.alloc.free(partials);

    var got: u64 = 0;
    for (partials) |p| got += p;

    if (got != expected) {
        std.debug.print("sum mismatch (n={d} tile={d}): got {d} want {d}\n", .{ n, tile, got, expected });
        return error.WrongResult;
    }
    std.debug.print("ok: reduce sum u32 n={d} tile={d} -> {d}\n", .{ n, tile, got });
}

fn runMax(session: *common.Session, n: u32, tile: u32) !void {
    const input = try session.alloc.alloc(i32, n);
    defer session.alloc.free(input);
    var expected: i32 = std.math.minInt(i32);
    for (input, 0..) |*p, i| {
        const v: i32 = @as(i32, @intCast(i & 0x7f)) - 64;
        p.* = v;
        expected = @max(expected, v);
    }

    const partials = try dispatch(i32, session, input, tile);
    defer session.alloc.free(partials);

    var got: i32 = std.math.minInt(i32);
    for (partials) |p| got = @max(got, p);

    if (got != expected) {
        std.debug.print("max mismatch (n={d} tile={d}): got {d} want {d}\n", .{ n, tile, got, expected });
        return error.WrongResult;
    }
    std.debug.print("ok: reduce max i32 n={d} tile={d} -> {d}\n", .{ n, tile, got });
}

fn dispatch(
    comptime T: type,
    session: *common.Session,
    input: []const T,
    tile: u32,
) ![]T {
    const n: u32 = @intCast(input.len);
    if (n % tile != 0) return error.InvalidArgument;
    const partials = n / tile;
    if (partials % WORKGROUP_SIZE != 0) return error.InvalidArgument;

    var in = try session.ctx.createBuffer(T, input.len);
    defer in.deinit();
    var out = try session.ctx.createBuffer(T, partials);
    defer out.deinit();

    try in.write(input);

    var pipeline = try session.ctx.loadPipeline(session.spv, .{
        .binding_count = 2,
        .push_constant_size = @sizeOf(Push),
    });
    defer pipeline.deinit();

    const push = Push{ .n = n, .tile = tile };
    try pipeline.dispatch(&.{ in.bind(), out.bind() }, .{
        .groups = .{ partials / WORKGROUP_SIZE, 1, 1 },
        .push = std.mem.asBytes(&push),
    });

    return try out.read(session.alloc);
}
