// Usage: ./wg_reduce <kernel.spv> <sum|max>
//
// Single-workgroup tree reduction. The kernel reduces the entire input
// internally using shared scratch + barriers, so the host just collects
// the one-element result.

const std = @import("std");
const molten = @import("molten");

const N: u32 = 2048;

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
        try runSum(alloc, &ctx, spv);
    } else if (std.mem.eql(u8, op_arg, "max")) {
        try runMax(alloc, &ctx, spv);
    } else {
        return error.BadArgs;
    }
}

fn runSum(alloc: std.mem.Allocator, ctx: *molten.Context, spv: []const u8) !void {
    var input: [N]u32 = undefined;
    var expected: u64 = 0;
    for (0..N) |i| {
        input[i] = @intCast(i & 0xff);
        expected += input[i];
    }
    const got = try dispatch(u32, alloc, ctx, spv, &input);
    if (got != expected) {
        std.debug.print("sum mismatch: got {d} want {d}\n", .{ got, expected });
        return error.WrongResult;
    }
    std.debug.print("ok: wg_reduce sum u32 -> {d}\n", .{got});
}

fn runMax(alloc: std.mem.Allocator, ctx: *molten.Context, spv: []const u8) !void {
    var input: [N]i32 = undefined;
    var expected: i32 = std.math.minInt(i32);
    for (0..N) |i| {
        const v: i32 = @as(i32, @intCast(i & 0x7f)) - 64;
        input[i] = v;
        expected = @max(expected, v);
    }
    const got = try dispatch(i32, alloc, ctx, spv, &input);
    if (got != expected) {
        std.debug.print("max mismatch: got {d} want {d}\n", .{ got, expected });
        return error.WrongResult;
    }
    std.debug.print("ok: wg_reduce max i32 -> {d}\n", .{got});
}

fn dispatch(
    comptime T: type,
    alloc: std.mem.Allocator,
    ctx: *molten.Context,
    spv: []const u8,
    input: []const T,
) !T {
    var in = try ctx.createBuffer(T, input.len);
    defer in.deinit();
    var out = try ctx.createBuffer(T, 1);
    defer out.deinit();

    try in.write(input);

    var pipeline = try ctx.loadPipeline(spv, 2);
    defer pipeline.deinit();
    try pipeline.dispatch(&.{ in.bind(), out.bind() }, .{ .groups = .{ 1, 1, 1 } });

    const result = try out.read(alloc);
    defer alloc.free(result);
    return result[0];
}
