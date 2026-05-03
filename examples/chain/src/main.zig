// Usage: ./chain <kernel.spv> [--binary]
//
// Two-pass GPU reduction chained on the device. Default uses a Timeline;
// --binary uses the binary Semaphore + Fence pair instead.

const std = @import("std");
const molten = @import("molten");

const WORKGROUP_SIZE: u32 = 64;
const N: u32 = 1 << 14;
const TILE1: u32 = 64;

const Push = extern struct { n: u32, tile: u32 };

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer arg_it.deinit();
    _ = arg_it.next() orelse return error.BadArgs;
    const spv_path = arg_it.next() orelse return error.BadArgs;
    var use_binary = false;
    while (arg_it.next()) |a| {
        if (std.mem.eql(u8, a, "--binary")) use_binary = true else return error.BadArgs;
    }

    const spv = try std.Io.Dir.cwd().readFileAlloc(init.io, spv_path, alloc, .limited(64 * 1024 * 1024));
    defer alloc.free(spv);

    var ctx = try molten.Context.init(alloc, .{});
    defer ctx.deinit();
    std.debug.print("device: {s}\n", .{ctx.deviceName()});

    // N inputs -> P1 -> partials (N/TILE1) -> P2 -> final (1).
    const partials_count = N / TILE1;
    const tile2 = partials_count;
    if (partials_count % WORKGROUP_SIZE != 0) return error.InvalidArgument;

    const input = try alloc.alloc(u32, N);
    defer alloc.free(input);
    var expected: u64 = 0;
    for (input, 0..) |*p, i| {
        p.* = @intCast(i & 0xff);
        expected += p.*;
    }

    var in_buf = try ctx.createBuffer(u32, N);
    defer in_buf.deinit();
    var partials_buf = try ctx.createBuffer(u32, partials_count);
    defer partials_buf.deinit();
    var final_buf = try ctx.createBuffer(u32, 1);
    defer final_buf.deinit();
    try in_buf.write(input);

    var pipeline = try ctx.loadPipeline(spv, .{
        .binding_count = 2,
        .push_constant_size = @sizeOf(Push),
    });
    defer pipeline.deinit();

    var cmd1 = try molten.CommandBuffer.init(&ctx);
    defer cmd1.deinit();
    var cmd2 = try molten.CommandBuffer.init(&ctx);
    defer cmd2.deinit();

    const push1 = Push{ .n = N, .tile = TILE1 };
    try cmd1.begin();
    try pipeline.record(&cmd1, &.{ in_buf.bind(), partials_buf.bind() }, .{
        .groups = .{ partials_count / WORKGROUP_SIZE, 1, 1 },
        .push = std.mem.asBytes(&push1),
    });
    cmd1.barrierComputeToCompute();
    try cmd1.end();

    const push2 = Push{ .n = partials_count, .tile = tile2 };
    try cmd2.begin();
    try pipeline.record(&cmd2, &.{ partials_buf.bind(), final_buf.bind() }, .{
        .groups = .{ 1, 1, 1 },
        .push = std.mem.asBytes(&push2),
    });
    cmd2.barrierComputeToHost();
    try cmd2.end();

    if (use_binary) {
        var sem = try molten.Semaphore.init(&ctx);
        defer sem.deinit();
        var fence = try molten.Fence.init(&ctx);
        defer fence.deinit();

        try ctx.submit(.{ .cmd = &cmd1, .signals = &.{&sem} });
        try ctx.submit(.{
            .cmd = &cmd2,
            .waits = &.{.{ .semaphore = &sem, .stage = molten.PipelineStage.compute_shader }},
            .fence = &fence,
        });
        try fence.wait(std.math.maxInt(u64));
    } else {
        var tl = try molten.Timeline.init(&ctx, 0);
        defer tl.deinit();

        try ctx.submit(.{
            .cmd = &cmd1,
            .timeline_signals = &.{.{ .timeline = &tl, .value = 1 }},
        });
        try ctx.submit(.{
            .cmd = &cmd2,
            .timeline_waits = &.{.{
                .timeline = &tl,
                .value = 1,
                .stage = molten.PipelineStage.compute_shader,
            }},
            .timeline_signals = &.{.{ .timeline = &tl, .value = 2 }},
        });
        try tl.wait(2, std.math.maxInt(u64));
    }

    pipeline.ringReset();

    const result = try final_buf.read(alloc);
    defer alloc.free(result);
    const got: u64 = result[0];
    if (got != expected) {
        std.debug.print("chain mismatch: got {d} want {d}\n", .{ got, expected });
        return error.WrongResult;
    }
    const mode: []const u8 = if (use_binary) "binary+fence" else "timeline";
    std.debug.print("ok: chain sum u32 N={d} -> {d} (sync={s})\n", .{ N, got, mode });
}
