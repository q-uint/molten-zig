// Usage: ./reduce <kernel.spv> <sum|max>

const std = @import("std");
const molten = @import("molten");

const WORKGROUP_SIZE: u32 = 64;
const Push = extern struct { n: u32, tile: u32 };

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer arg_it.deinit();
    _ = arg_it.next() orelse return error.BadArgs;
    const spv_path = arg_it.next() orelse return error.BadArgs;
    const op_arg = arg_it.next() orelse return error.BadArgs;

    const spv = try std.Io.Dir.cwd().readFileAlloc(init.io, spv_path, alloc, .limited(64 * 1024 * 1024));
    defer alloc.free(spv);

    var ctx = try molten.Context.init(alloc, .{});
    defer ctx.deinit();
    std.debug.print("device: {s}\n", .{ctx.deviceName()});

    if (std.mem.eql(u8, op_arg, "sum")) {
        try runSum(alloc, &ctx, spv, 1 << 14, 64);
        try runSum(alloc, &ctx, spv, 1 << 16, 128);
    } else if (std.mem.eql(u8, op_arg, "max")) {
        try runMax(alloc, &ctx, spv, 1 << 14, 64);
        try runMax(alloc, &ctx, spv, 1 << 16, 128);
    } else {
        return error.BadArgs;
    }
}

fn runSum(alloc: std.mem.Allocator, ctx: *molten.Context, spv: []const u8, n: u32, tile: u32) !void {
    const input = try alloc.alloc(u32, n);
    defer alloc.free(input);
    var expected: u64 = 0;
    for (input, 0..) |*p, i| {
        p.* = @intCast(i & 0xff);
        expected += p.*;
    }

    const partials = try dispatch(u32, alloc, ctx, spv, input, tile);
    defer alloc.free(partials);

    var got: u64 = 0;
    for (partials) |p| got += p;

    if (got != expected) {
        std.debug.print("sum mismatch (n={d} tile={d}): got {d} want {d}\n", .{ n, tile, got, expected });
        return error.WrongResult;
    }
    std.debug.print("ok: reduce sum u32 n={d} tile={d} -> {d}\n", .{ n, tile, got });
}

fn runMax(alloc: std.mem.Allocator, ctx: *molten.Context, spv: []const u8, n: u32, tile: u32) !void {
    const input = try alloc.alloc(i32, n);
    defer alloc.free(input);
    var expected: i32 = std.math.minInt(i32);
    for (input, 0..) |*p, i| {
        const v: i32 = @as(i32, @intCast(i & 0x7f)) - 64;
        p.* = v;
        expected = @max(expected, v);
    }

    const partials = try dispatch(i32, alloc, ctx, spv, input, tile);
    defer alloc.free(partials);

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
    alloc: std.mem.Allocator,
    ctx: *molten.Context,
    spv: []const u8,
    input: []const T,
    tile: u32,
) ![]T {
    const n: u32 = @intCast(input.len);
    if (n % tile != 0) return error.InvalidArgument;
    const partials = n / tile;
    if (partials % WORKGROUP_SIZE != 0) return error.InvalidArgument;

    var in = try ctx.createBuffer(T, input.len);
    defer in.deinit();
    var out = try ctx.createBuffer(T, partials);
    defer out.deinit();

    try in.write(input);

    var pipeline = try ctx.loadPipeline(spv, .{
        .binding_count = 2,
        .push_constant_size = @sizeOf(Push),
    });
    defer pipeline.deinit();

    const push = Push{ .n = n, .tile = tile };
    try pipeline.dispatch(&.{ in.bind(), out.bind() }, .{
        .groups = .{ partials / WORKGROUP_SIZE, 1, 1 },
        .push = std.mem.asBytes(&push),
    });

    return try out.read(alloc);
}
