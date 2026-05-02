// Usage: ./reduce <kernel.spv> <sum|max>
//
// Each invocation reduces TILE input elements; the host folds the
// per-invocation partials. Picking sum or max only changes the host-side
// reference computation - the kernel decides what the operation is.

const std = @import("std");
const molten = @import("molten");

const N: u32 = 1 << 14;
const TILE: u32 = 64;
const PARTIALS: u32 = N / TILE;
// Must match the workgroup_size baked into the kernel via gpu.executionMode.
const WORKGROUP_SIZE: u32 = 64;

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

    const partials = try dispatch(u32, alloc, ctx, spv, &input);
    defer alloc.free(partials);

    var got: u64 = 0;
    for (partials) |p| got += p;

    if (got != expected) {
        std.debug.print("sum mismatch: got {d} want {d}\n", .{ got, expected });
        return error.WrongResult;
    }
    std.debug.print("ok: reduce sum u32 -> {d}\n", .{got});
}

fn runMax(alloc: std.mem.Allocator, ctx: *molten.Context, spv: []const u8) !void {
    var input: [N]i32 = undefined;
    var expected: i32 = std.math.minInt(i32);
    for (0..N) |i| {
        // Mix sign so the i32 minInt identity actually matters.
        const v: i32 = @as(i32, @intCast(i & 0x7f)) - 64;
        input[i] = v;
        expected = @max(expected, v);
    }

    const partials = try dispatch(i32, alloc, ctx, spv, &input);
    defer alloc.free(partials);

    var got: i32 = std.math.minInt(i32);
    for (partials) |p| got = @max(got, p);

    if (got != expected) {
        std.debug.print("max mismatch: got {d} want {d}\n", .{ got, expected });
        return error.WrongResult;
    }
    std.debug.print("ok: reduce max i32 -> {d}\n", .{got});
}

fn dispatch(
    comptime T: type,
    alloc: std.mem.Allocator,
    ctx: *molten.Context,
    spv: []const u8,
    input: []const T,
) ![]T {
    var in = try ctx.createBuffer(T, input.len);
    defer in.deinit();
    var out = try ctx.createBuffer(T, PARTIALS);
    defer out.deinit();

    try in.write(input);

    var pipeline = try ctx.loadPipeline(spv, 2);
    defer pipeline.deinit();
    try pipeline.dispatch(&.{ in.bind(), out.bind() }, .{ .groups = .{ PARTIALS / WORKGROUP_SIZE, 1, 1 } });

    return try out.read(alloc);
}
