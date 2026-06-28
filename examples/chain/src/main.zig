// Usage: ./chain <kernel.spv> [--binary]
//
// Two-pass GPU reduction looped over a 2-frame FramePool ring. Default uses
// a Timeline for inter-pass sync; --binary uses Semaphore + Fence.

const std = @import("std");
const spritz = @import("spritz");

const WORKGROUP_SIZE: u32 = 64;
const N: u32 = 1 << 14;
const TILE1: u32 = 64;
const FRAMES: usize = 2;
const ITERATIONS: usize = 4;

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

    var ctx = try spritz.Context.init(alloc, .{});
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

    // ITERATIONS * 2 descriptor slots; the ring is reset once at the end.
    var pipeline = try ctx.loadPipeline(spv, .{
        .binding_count = 2,
        .push_constant_size = @sizeOf(Push),
        .descriptor_ring_size = ITERATIONS * 2,
    });
    defer pipeline.deinit();

    var frames: [FRAMES]spritz.FramePool = undefined;
    var frames_inited: usize = 0;
    defer for (frames[0..frames_inited]) |*f| f.deinit();
    while (frames_inited < FRAMES) : (frames_inited += 1) {
        frames[frames_inited] = try spritz.FramePool.init(&ctx, .{ .capacity = 2 });
    }

    // Per-frame inter-pass sync; safe to reuse because the frame's fence
    // gates each iteration on the prior submission completing.
    var sems: [FRAMES]spritz.Semaphore = undefined;
    var tls: [FRAMES]spritz.Timeline = undefined;
    var sync_inited: usize = 0;
    defer if (use_binary) {
        for (sems[0..sync_inited]) |*s| s.deinit();
    } else {
        for (tls[0..sync_inited]) |*t| t.deinit();
    };
    if (use_binary) {
        while (sync_inited < FRAMES) : (sync_inited += 1) {
            sems[sync_inited] = try spritz.Semaphore.init(&ctx);
        }
    } else {
        while (sync_inited < FRAMES) : (sync_inited += 1) {
            tls[sync_inited] = try spritz.Timeline.init(&ctx, 0);
        }
    }

    const push1 = Push{ .n = N, .tile = TILE1 };
    const push2 = Push{ .n = partials_count, .tile = tile2 };

    for (0..ITERATIONS) |iter| {
        const slot = iter % FRAMES;
        const frame = &frames[slot];
        try frame.waitAndReset(std.math.maxInt(u64));

        var cmd1 = frame.get(0);
        var cmd2 = frame.get(1);

        try cmd1.begin();
        try pipeline.record(&cmd1, &.{ in_buf.bind(), partials_buf.bind() }, .{
            .groups = .{ partials_count / WORKGROUP_SIZE, 1, 1 },
            .push = std.mem.asBytes(&push1),
        });
        cmd1.barrierComputeToCompute();
        try cmd1.end();

        try cmd2.begin();
        try pipeline.record(&cmd2, &.{ partials_buf.bind(), final_buf.bind() }, .{
            .groups = .{ 1, 1, 1 },
            .push = std.mem.asBytes(&push2),
        });
        cmd2.barrierComputeToHost();
        try cmd2.end();

        if (use_binary) {
            try ctx.submit(.{ .cmd = &cmd1, .signals = &.{&sems[slot]} });
            try ctx.submit(.{
                .cmd = &cmd2,
                .waits = &.{.{ .semaphore = &sems[slot], .stage = spritz.PipelineStage.compute_shader }},
                .fence = &frame.fence,
            });
        } else {
            // Timeline values strictly increase per submit on the same timeline.
            const v1: u64 = @intCast(iter * 2 + 1);
            const v2: u64 = @intCast(iter * 2 + 2);
            try ctx.submit(.{
                .cmd = &cmd1,
                .timeline_signals = &.{.{ .timeline = &tls[slot], .value = v1 }},
            });
            try ctx.submit(.{
                .cmd = &cmd2,
                .timeline_waits = &.{.{
                    .timeline = &tls[slot],
                    .value = v1,
                    .stage = spritz.PipelineStage.compute_shader,
                }},
                .timeline_signals = &.{.{ .timeline = &tls[slot], .value = v2 }},
                .fence = &frame.fence,
            });
        }
    }

    // Drain all frames before reading the shared final_buf.
    for (&frames) |*f| try f.fence.wait(std.math.maxInt(u64));
    pipeline.ringReset();

    const result = try final_buf.read(alloc);
    defer alloc.free(result);
    const got: u64 = result[0];
    if (got != expected) {
        std.debug.print("chain mismatch: got {d} want {d}\n", .{ got, expected });
        return error.WrongResult;
    }
    const mode: []const u8 = if (use_binary) "binary+fence" else "timeline";
    std.debug.print(
        "ok: chain sum u32 N={d} iters={d} -> {d} (sync={s})\n",
        .{ N, ITERATIONS, got, mode },
    );
}
