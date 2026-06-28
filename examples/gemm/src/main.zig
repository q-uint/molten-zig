// Usage: ./gemm <kernel.spv> [--bench]
//
// f32 row-major GEMM, square M = N = K. Dispatches the kernel, runs the
// same multiply through a portable CPU reference, compares element-wise
// with relative tolerance, and prints GFLOP/s for both. With --bench,
// follows up with steady-state timing via the shared bench harness.

const std = @import("std");
const common = @import("common");

const M: u32 = 1024;
const N: u32 = 1024;
const K: u32 = 1024;
const TILE: u32 = 16;
const TOL: f32 = 1e-3;

const Push = extern struct { m: u32, n: u32, k: u32 };

// Portable CPU reference: C = A * B, row-major, square. The ikj loop order
// streams contiguous rows of B and C in the innermost loop, which the
// optimizer vectorizes under ReleaseFast - a self-contained baseline that
// needs no system BLAS.
fn refSgemm(a: []const f32, b: []const f32, c: []f32, m: u32, n: u32, k: u32) void {
    @memset(c, 0);
    var i: u32 = 0;
    while (i < m) : (i += 1) {
        const c_row = c[i * n ..][0..n];
        const a_row = a[i * k ..][0..k];
        var p: u32 = 0;
        while (p < k) : (p += 1) {
            const a_ip = a_row[p];
            const b_row = b[p * n ..][0..n];
            for (c_row, b_row) |*cv, bv| cv.* += a_ip * bv;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    const args = try common.Args.parse(init, alloc);
    defer args.deinit(alloc);
    const want_bench = args.rest.len > 0 and std.mem.eql(u8, args.rest[0], "--bench");

    const a_host = try alloc.alloc(f32, M * K);
    defer alloc.free(a_host);
    const b_host = try alloc.alloc(f32, K * N);
    defer alloc.free(b_host);
    const c_ref = try alloc.alloc(f32, M * N);
    defer alloc.free(c_ref);

    // Deterministic, bounded inputs - keeps the f32 sums well-behaved.
    for (a_host, 0..) |*p, i| p.* = @sin(@as(f32, @floatFromInt(i)) * 0.001);
    for (b_host, 0..) |*p, i| p.* = @cos(@as(f32, @floatFromInt(i)) * 0.001);

    var session = try common.Session.open(init, alloc, args.spv_path);
    defer session.deinit();

    var a_buf = try session.ctx.createBuffer(f32, M * K);
    defer a_buf.deinit();
    var b_buf = try session.ctx.createBuffer(f32, K * N);
    defer b_buf.deinit();
    var c_buf = try session.ctx.createBuffer(f32, M * N);
    defer c_buf.deinit();

    try a_buf.write(a_host);
    try b_buf.write(b_host);

    var pipeline = try session.ctx.loadPipeline(session.spv, .{
        .binding_count = 3,
        .push_constant_size = @sizeOf(Push),
    });
    defer pipeline.deinit();

    const push = Push{ .m = M, .n = N, .k = K };
    const groups: [3]u32 = .{ (N + TILE - 1) / TILE, (M + TILE - 1) / TILE, 1 };

    const clock = std.Io.Clock.awake;
    const t0 = clock.now(init.io);
    try pipeline.dispatch(&.{ a_buf.bind(), b_buf.bind(), c_buf.bind() }, .{
        .groups = groups,
        .push = std.mem.asBytes(&push),
    });
    const c_got = try c_buf.read(alloc);
    defer alloc.free(c_got);
    const t1 = clock.now(init.io);
    refSgemm(a_host, b_host, c_ref, M, N, K);
    const t2 = clock.now(init.io);
    const gpu_s = secondsBetween(t0, t1);
    const cpu_s = secondsBetween(t1, t2);

    var max_rel: f32 = 0.0;
    for (c_got, c_ref, 0..) |got, want, i| {
        const denom = @max(@abs(want), 1e-6);
        const rel = @abs(got - want) / denom;
        if (rel > max_rel) max_rel = rel;
        if (rel > TOL) {
            std.debug.print("mismatch at {d}: got {d} want {d} (rel {d})\n", .{ i, got, want, rel });
            return error.WrongResult;
        }
    }

    const flops: f64 = 2.0 * @as(f64, @floatFromInt(M)) * @as(f64, @floatFromInt(N)) * @as(f64, @floatFromInt(K));
    std.debug.print(
        "ok: gemm {d}x{d}x{d} max_rel={e:.2}\n  gpu (dispatch+readback): {d:>8.3} ms  {d:>6.1} GFLOP/s\n  cpu (zig reference):     {d:>8.3} ms  {d:>6.1} GFLOP/s\n",
        .{
            M,              N,                   K,              max_rel,
            gpu_s * 1000.0, flops / gpu_s / 1e9, cpu_s * 1000.0, flops / cpu_s / 1e9,
        },
    );

    if (!want_bench) return;

    var label_buf: [64]u8 = undefined;
    _ = try session.runBench(.{
        .label = common.benchLabel(&label_buf, "gemm", args.spv_path, null),
        .pipeline = &pipeline,
        .bindings = &.{ a_buf.bind(), b_buf.bind(), c_buf.bind() },
        .groups = groups,
        .push = std.mem.asBytes(&push),
        .work = .{ .flops = @intFromFloat(flops) },
    });
}

fn secondsBetween(start: std.Io.Timestamp, end: std.Io.Timestamp) f64 {
    const ns: i64 = @intCast(start.durationTo(end).nanoseconds);
    return @as(f64, @floatFromInt(ns)) / 1e9;
}
