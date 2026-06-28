// Shared microbenchmark harness for example kernels.
//
// Times steady-state dispatch + fence-wait wall-clock around a prebuilt
// pipeline. Pairs with common.run: verify once, then hand the same
// pipeline/bindings to bench.run() to measure.
//
// Output is one line per call, stable column order:
//   bench: <label> | N=<runs> inner=<inner> | min=<...> p50=<...> p99=<...> +-<stddev> | <throughput>

const std = @import("std");
const spritz = @import("spritz");

pub const Work = union(enum) {
    /// Bytes moved per dispatch (in + out). Reported as GB/s.
    bytes: u64,
    /// Floating-point ops per dispatch. Reported as GFLOP/s.
    flops: u64,
    none,
};

pub const Options = struct {
    label: []const u8,
    io: std.Io,
    ctx: *spritz.Context,
    pipeline: *spritz.Pipeline,
    bindings: []const spritz.BindEntry,
    groups: [3]u32,
    push: ?[]const u8 = null,
    /// Per-batch dispatch count. Clamped to the pipeline's
    /// descriptor_ring_size; bump that in PipelineOptions to batch more.
    inner: u32 = 4,
    /// Untimed warmup batches. First-dispatch MSL compile on MoltenVK is
    /// 10-100x; a few batches reliably swallow it.
    warmup: u32 = 3,
    /// Timed batches. Min over this many is the headline number; more
    /// samples tighten p99 but extend wall time linearly.
    samples: u32 = 32,
    work: Work = .none,
    /// nanoseconds; default 5s per fence wait. Bench dispatches shouldn't
    /// hit this in practice - it exists to fail loud instead of hanging.
    timeout_ns: u64 = 5 * std.time.ns_per_s,
};

pub const Stats = struct {
    samples: u32,
    inner: u32,
    min_ns: u64,
    p50_ns: u64,
    p99_ns: u64,
    mean_ns: f64,
    stddev_ns: f64,
    /// Per-dispatch pure-GPU time from timestamp queries, null when the device
    /// has no usable timestamp support. Wall-clock (the fields above) always set.
    gpu_min_ns: ?u64 = null,
};

pub fn run(options: Options) !Stats {
    var pipeline = options.pipeline;
    const inner = @min(options.inner, pipeline.ring_size);

    var fence = try spritz.Fence.init(options.ctx);
    defer fence.deinit();

    var cmd = try spritz.CommandBuffer.init(options.ctx);
    defer cmd.deinit();

    // Two timestamps bracket each batch; pure-GPU time only when the device
    // supports it. null pool => wall-clock only, no behavioral change.
    var pool: ?spritz.QueryPool = if (options.ctx.timestampsSupported())
        try spritz.QueryPool.init(options.ctx, 2)
    else
        null;
    defer if (pool) |*p| p.deinit();

    for (0..options.warmup) |_| {
        try recordBatch(&cmd, pipeline, options, inner, if (pool) |*p| p else null);
        try options.ctx.submit(.{ .cmd = &cmd, .fence = &fence });
        try fence.wait(options.timeout_ns);
        try fence.reset();
        pipeline.ringReset();
        try cmd.reset();
    }

    const alloc = options.ctx.allocator;
    const per_dispatch_ns = try alloc.alloc(u64, options.samples);
    defer alloc.free(per_dispatch_ns);
    const gpu_per_dispatch_ns = try alloc.alloc(u64, options.samples);
    defer alloc.free(gpu_per_dispatch_ns);

    const clock = std.Io.Clock.awake;
    for (per_dispatch_ns, gpu_per_dispatch_ns) |*slot, *gpu_slot| {
        try recordBatch(&cmd, pipeline, options, inner, if (pool) |*p| p else null);
        const t0 = clock.now(options.io);
        try options.ctx.submit(.{ .cmd = &cmd, .fence = &fence });
        try fence.wait(options.timeout_ns);
        const t1 = clock.now(options.io);
        if (pool) |*p| gpu_slot.* = (try p.elapsedNs(0, 1)) / inner;
        try fence.reset();
        pipeline.ringReset();
        try cmd.reset();
        const batch_ns: u64 = @intCast(t0.durationTo(t1).nanoseconds);
        slot.* = batch_ns / inner;
    }

    var stats = summarise(per_dispatch_ns, options.samples, inner);
    if (pool != null) {
        std.mem.sort(u64, gpu_per_dispatch_ns, {}, std.sort.asc(u64));
        stats.gpu_min_ns = gpu_per_dispatch_ns[0];
    }
    printLine(options.label, stats, options.work);
    return stats;
}

fn recordBatch(
    cmd: *spritz.CommandBuffer,
    pipeline: *spritz.Pipeline,
    options: Options,
    inner: u32,
    pool: ?*spritz.QueryPool,
) !void {
    try cmd.begin();
    if (pool) |p| {
        p.reset(cmd);
        p.writeTimestamp(cmd, spritz.PipelineStage.top_of_pipe, 0);
    }
    for (0..inner) |i| {
        try pipeline.record(cmd, options.bindings, .{
            .groups = options.groups,
            .push = options.push orelse &.{},
        });
        // Compute->compute barrier between dispatches so the driver can't
        // overlap them; we want `inner` serial dispatches per batch.
        if (i + 1 < inner) cmd.barrierComputeToCompute();
    }
    if (pool) |p| p.writeTimestamp(cmd, spritz.PipelineStage.compute_shader, 1);
    cmd.barrierComputeToHost();
    try cmd.end();
}

fn summarise(samples: []u64, n: u32, inner: u32) Stats {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const min_ns = samples[0];
    const p50_ns = samples[samples.len / 2];
    const p99_idx = @min((samples.len * 99 + 99) / 100 - 1, samples.len - 1);
    const p99_ns = samples[p99_idx];

    var sum: f64 = 0;
    for (samples) |s| sum += @floatFromInt(s);
    const mean_ns = sum / @as(f64, @floatFromInt(samples.len));

    var sq: f64 = 0;
    for (samples) |s| {
        const d = @as(f64, @floatFromInt(s)) - mean_ns;
        sq += d * d;
    }
    const stddev_ns = @sqrt(sq / @as(f64, @floatFromInt(samples.len)));

    return .{
        .samples = n,
        .inner = inner,
        .min_ns = min_ns,
        .p50_ns = p50_ns,
        .p99_ns = p99_ns,
        .mean_ns = mean_ns,
        .stddev_ns = stddev_ns,
    };
}

fn printLine(label: []const u8, s: Stats, work: Work) void {
    var min_b: [16]u8 = undefined;
    var p50_b: [16]u8 = undefined;
    var p99_b: [16]u8 = undefined;
    var sd_b: [16]u8 = undefined;
    std.debug.print(
        "bench: {s} | N={d} inner={d} | min={s} p50={s} p99={s} +-{s}",
        .{
            label,                                                s.samples,                 s.inner,
            fmtTime(&min_b, s.min_ns),                            fmtTime(&p50_b, s.p50_ns), fmtTime(&p99_b, s.p99_ns),
            fmtTime(&sd_b, @as(u64, @intFromFloat(s.stddev_ns))),
        },
    );
    switch (work) {
        .bytes => |b| {
            const gbs = @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(s.min_ns));
            std.debug.print(" | {d:.2} GB/s", .{gbs});
        },
        .flops => |f| {
            const gfs = @as(f64, @floatFromInt(f)) / @as(f64, @floatFromInt(s.min_ns));
            std.debug.print(" | {d:.2} GFLOP/s", .{gfs});
        },
        .none => {},
    }
    // Pure-GPU min from timestamps, after the wall-clock line so the headline
    // throughput stays first. gpu < wall by the submit/fence/readback overhead.
    if (s.gpu_min_ns) |g| {
        var gpu_b: [16]u8 = undefined;
        std.debug.print(" | gpu={s}", .{fmtTime(&gpu_b, g)});
    }
    std.debug.print("\n", .{});
}

fn fmtTime(buf: []u8, ns: u64) []const u8 {
    if (ns < 1000) return std.fmt.bufPrint(buf, "{d}ns", .{ns}) catch unreachable;
    if (ns < 1_000_000) return std.fmt.bufPrint(buf, "{d:.2}us", .{@as(f64, @floatFromInt(ns)) / 1e3}) catch unreachable;
    if (ns < 1_000_000_000) return std.fmt.bufPrint(buf, "{d:.2}ms", .{@as(f64, @floatFromInt(ns)) / 1e6}) catch unreachable;
    return std.fmt.bufPrint(buf, "{d:.2}s", .{@as(f64, @floatFromInt(ns)) / 1e9}) catch unreachable;
}
