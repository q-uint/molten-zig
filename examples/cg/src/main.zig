// Run with `zig build run` (build.zig compiles every kernel and passes the
// spv paths positionally, in kernels.KernelId order).
//
// GPU-resident conjugate gradient on the 1D Poisson system. Every scalar (the
// dot results, alpha, beta, and the stopping threshold) lives in a device
// buffer and is produced and consumed by kernels, so no scalar round-trips
// through the host arithmetic. The host reads back only a one-word `done` flag
// each iteration, to decide whether to keep submitting, plus the final x.
// Parity-checked against the CPU reference in cg.zig, which uses the same f32
// recurrence.
//
// Cold start: x = 0, so r0 = b and p0 = b. We seed r and p on the host to skip
// the initial matvec/subtract. Everything after is on-device.

const std = @import("std");
const molten = @import("molten");
const cg = @import("cg.zig");
const kernels = @import("kernels.zig");

const WG: u32 = 64;
const SLOTS: u32 = @intFromEnum(kernels.ScalarSlot._count);

const MAX_ITERS: u32 = 20000;
const TOL: f32 = 1e-5;
const PARITY_TOL: f32 = 1e-3; // f32 dot reorders vs CPU's strict sum

// Sweep several sizes so a size-dependent indexing/tiling bug can't hide behind
// one lucky dimension. Constraints: n % tile == 0 and (n/tile) % WG == 0, so
// the partial-reduction grid is whole workgroups. The cases span one workgroup
// of partials (256, 1024) up to many (4096, 8192).
const Problem = struct { n: u32, tile: u32 };
const SIZES = [_]Problem{
    .{ .n = 256, .tile = 4 }, // partials = 64  = 1 workgroup
    .{ .n = 1024, .tile = 16 }, // partials = 64  = 1 workgroup
    .{ .n = 4096, .tile = 4 }, // partials = 1024 = 16 workgroups
    .{ .n = 8192, .tile = 2 }, // partials = 4096 = 64 workgroups
};

const DotPush = extern struct { n: u32, tile: u32 };
const FinishPush = extern struct { partials: u32, slot: u32 };
const AxpyPush = extern struct { n: u32, sign: f32 };
const NPush = extern struct { n: u32 };
const TolPush = extern struct { tol2: f32 };

const Kernels = struct {
    matvec: molten.Pipeline,
    dot: molten.Pipeline,
    finish: molten.Pipeline,
    alpha: molten.Pipeline,
    beta: molten.Pipeline,
    axpy: molten.Pipeline,
    updatep: molten.Pipeline,
    init_stop: molten.Pipeline,
    check: molten.Pipeline,

    fn each(self: *Kernels, comptime method: []const u8) void {
        inline for (.{ "matvec", "dot", "finish", "alpha", "beta", "axpy", "updatep", "init_stop", "check" }) |f| {
            @call(.auto, @field(@TypeOf(@field(self, f)), method), .{&@field(self, f)});
        }
    }
    fn deinit(self: *Kernels) void {
        self.each("deinit");
    }
    fn ringReset(self: *Kernels) void {
        self.each("ringReset");
    }
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer it.deinit();
    _ = it.next() orelse return error.BadArgs;
    var paths: [kernels.KernelId.count][]const u8 = undefined;
    for (&paths) |*p| p.* = it.next() orelse return error.BadArgs;

    var ctx = try molten.Context.init(alloc, .{});
    defer ctx.deinit();
    std.debug.print("device: {s}\n", .{ctx.deviceName()});

    var ks = try loadAll(&ctx, init.io, alloc, paths);
    defer ks.deinit();

    for (SIZES) |prob| try solveAndCheck(&ctx, &ks, alloc, prob);
}

fn solveAndCheck(ctx: *molten.Context, ks: *Kernels, alloc: std.mem.Allocator, prob: Problem) !void {
    const n = prob.n;
    const tile = prob.tile;
    const partials: u32 = n / tile;
    if (n % tile != 0 or partials % WG != 0) return error.InvalidArgument;

    // f = 1 scaled by h^2; the analytic solution is the parabola checked in cg.zig.
    const b = try alloc.alloc(f32, n);
    defer alloc.free(b);
    const h: f32 = 1.0 / @as(f32, @floatFromInt(n + 1));
    @memset(b, h * h);

    const ref = try cpuReference(alloc, b);
    defer alloc.free(ref);

    const got = try gpuSolve(ctx, ks, alloc, b, prob, partials);
    defer alloc.free(got);

    var max_err: f32 = 0;
    for (got, ref) |g, r| max_err = @max(max_err, @abs(g - r));
    if (max_err > PARITY_TOL) {
        std.debug.print("cg parity FAIL: N={d} tile={d} max|gpu - cpu| = {d} (tol {d})\n", .{ n, tile, max_err, PARITY_TOL });
        return error.WrongResult;
    }
    std.debug.print("ok: cg gpu-resident N={d} tile={d} max|gpu - cpu| = {e} (tol {d})\n", .{ n, tile, max_err, PARITY_TOL });
}

fn cpuReference(alloc: std.mem.Allocator, b: []const f32) ![]f32 {
    const n = b.len;
    var sys = Poisson{ .n = n };
    const x = try alloc.alloc(f32, n);
    errdefer alloc.free(x);
    const r = try alloc.alloc(f32, n);
    defer alloc.free(r);
    const p = try alloc.alloc(f32, n);
    defer alloc.free(p);
    const ap = try alloc.alloc(f32, n);
    defer alloc.free(ap);
    @memset(x, 0);
    _ = cg.solve(Poisson.apply, &sys, b, x, r, p, ap, .{ .tol = TOL, .max_iters = MAX_ITERS });
    return x;
}

const Poisson = struct {
    n: usize,
    fn apply(ctx: *anyopaque, x: []const f32, y: []f32) void {
        const self: *const Poisson = @ptrCast(@alignCast(ctx));
        const n = self.n;
        for (0..n) |i| {
            var v: f32 = 2.0 * x[i];
            if (i > 0) v -= x[i - 1];
            if (i + 1 < n) v -= x[i + 1];
            y[i] = v;
        }
    }
};

fn loadAll(ctx: *molten.Context, io: std.Io, alloc: std.mem.Allocator, paths: [kernels.KernelId.count][]const u8) !Kernels {
    const ring = 8; // max dispatches of any single kernel within one recorded submit
    const load = struct {
        fn one(c: *molten.Context, i: std.Io, a: std.mem.Allocator, path: []const u8, binding_count: u32, push: u32, r: u32) !molten.Pipeline {
            const spv = try std.Io.Dir.cwd().readFileAlloc(i, path, a, .limited(64 * 1024 * 1024));
            defer a.free(spv);
            return c.loadPipeline(spv, .{ .binding_count = binding_count, .push_constant_size = push, .descriptor_ring_size = r });
        }
    }.one;
    const at = struct {
        fn p(ps: [kernels.KernelId.count][]const u8, id: kernels.KernelId) []const u8 {
            return ps[@intFromEnum(id)];
        }
    }.p;

    return .{
        .matvec = try load(ctx, io, alloc, at(paths, .matvec), 2, @sizeOf(NPush), ring),
        .dot = try load(ctx, io, alloc, at(paths, .dot), 3, @sizeOf(DotPush), ring),
        .finish = try load(ctx, io, alloc, at(paths, .finish_dot), 2, @sizeOf(FinishPush), ring),
        .alpha = try load(ctx, io, alloc, at(paths, .compute_alpha), 1, 0, ring),
        .beta = try load(ctx, io, alloc, at(paths, .compute_beta), 1, 0, ring),
        .axpy = try load(ctx, io, alloc, at(paths, .axpy_alpha), 3, @sizeOf(AxpyPush), ring),
        .updatep = try load(ctx, io, alloc, at(paths, .update_p), 3, @sizeOf(NPush), ring),
        .init_stop = try load(ctx, io, alloc, at(paths, .init_stop), 1, @sizeOf(TolPush), ring),
        .check = try load(ctx, io, alloc, at(paths, .check_converged), 2, 0, ring),
    };
}

fn gpuSolve(ctx: *molten.Context, ks: *Kernels, alloc: std.mem.Allocator, b: []const f32, prob: Problem, partials: u32) ![]f32 {
    const n = prob.n;
    var x = try ctx.createBuffer(f32, n);
    defer x.deinit();
    var r = try ctx.createBuffer(f32, n);
    defer r.deinit();
    var p = try ctx.createBuffer(f32, n);
    defer p.deinit();
    var ap = try ctx.createBuffer(f32, n);
    defer ap.deinit();
    var part = try ctx.createBuffer(f32, partials);
    defer part.deinit();
    var scal = try ctx.createBuffer(f32, SLOTS);
    defer scal.deinit();
    var done = try ctx.createBuffer(u32, 1);
    defer done.deinit();

    // Cold start: x=0, r=b, p=b. Seed on host; loop is on-device after this.
    const zero = try alloc.alloc(f32, n);
    defer alloc.free(zero);
    @memset(zero, 0);
    try x.write(zero);
    try r.write(b);
    try p.write(b);

    const groups_n: [3]u32 = .{ (n + WG - 1) / WG, 1, 1 };
    const groups_part: [3]u32 = .{ partials / WG, 1, 1 };
    const dotp = DotPush{ .n = n, .tile = prob.tile };
    const np = NPush{ .n = n };

    var fence = try molten.Fence.init(ctx);
    defer fence.deinit();
    var cmd = try molten.CommandBuffer.init(ctx);
    defer cmd.deinit();

    // Initial rs_old = r.r (= b.b at cold start), then stop = tol^2 * rs_old.
    // Both on-device: the host never sees the residual, only the done flag.
    try cmd.begin();
    try recordDotInto(&cmd, ks, r.bind(), r.bind(), part.bind(), scal.bind(), dotp, partials, .rs_old, groups_part);
    const tolp = TolPush{ .tol2 = TOL * TOL };
    try ks.init_stop.record(&cmd, &.{scal.bind()}, .{ .groups = .{ 1, 1, 1 }, .push = std.mem.asBytes(&tolp) });
    cmd.barrierComputeToHost();
    try cmd.end();
    try submitWait(ctx, &cmd, &fence);
    ks.ringReset();

    var iter: u32 = 0;
    while (iter < MAX_ITERS) : (iter += 1) {
        try cmd.begin();
        // Ap = A p
        try ks.matvec.record(&cmd, &.{ p.bind(), ap.bind() }, .{ .groups = groups_n, .push = std.mem.asBytes(&np) });
        cmd.barrierComputeToCompute();
        // pap = p . Ap
        try recordDotInto(&cmd, ks, p.bind(), ap.bind(), part.bind(), scal.bind(), dotp, partials, .pap, groups_part);
        // alpha = rs_old / pap
        try ks.alpha.record(&cmd, &.{scal.bind()}, .{ .groups = .{ 1, 1, 1 } });
        cmd.barrierComputeToCompute();
        // x += alpha p ; r -= alpha Ap
        const axpy_pos = AxpyPush{ .n = n, .sign = 1.0 };
        const axpy_neg = AxpyPush{ .n = n, .sign = -1.0 };
        try ks.axpy.record(&cmd, &.{ x.bind(), p.bind(), scal.bind() }, .{ .groups = groups_n, .push = std.mem.asBytes(&axpy_pos) });
        try ks.axpy.record(&cmd, &.{ r.bind(), ap.bind(), scal.bind() }, .{ .groups = groups_n, .push = std.mem.asBytes(&axpy_neg) });
        cmd.barrierComputeToCompute();
        // rs_new = r . r ; done = (rs_new <= stop)
        try recordDotInto(&cmd, ks, r.bind(), r.bind(), part.bind(), scal.bind(), dotp, partials, .rs_new, groups_part);
        try ks.check.record(&cmd, &.{ scal.bind(), done.bind() }, .{ .groups = .{ 1, 1, 1 } });
        cmd.barrierComputeToHost();
        try cmd.end();
        try submitWait(ctx, &cmd, &fence);
        ks.ringReset();

        if (try readDone(&done, alloc)) {
            iter += 1;
            break;
        }

        // beta = rs_new / rs_old ; rs_old <- rs_new ; p = r + beta p
        try cmd.begin();
        try ks.beta.record(&cmd, &.{scal.bind()}, .{ .groups = .{ 1, 1, 1 } });
        cmd.barrierComputeToCompute();
        try ks.updatep.record(&cmd, &.{ p.bind(), r.bind(), scal.bind() }, .{ .groups = groups_n, .push = std.mem.asBytes(&np) });
        cmd.barrierComputeToHost();
        try cmd.end();
        try submitWait(ctx, &cmd, &fence);
        ks.ringReset();
    }
    std.debug.print("gpu CG iters: {d}\n", .{iter});

    return try x.read(alloc);
}

fn recordDotInto(
    cmd: *molten.CommandBuffer,
    ks: *Kernels,
    a: molten.BindEntry,
    b: molten.BindEntry,
    part: molten.BindEntry,
    scal: molten.BindEntry,
    dotp: DotPush,
    partials: u32,
    slot: kernels.ScalarSlot,
    groups_part: [3]u32,
) !void {
    try ks.dot.record(cmd, &.{ a, b, part }, .{ .groups = groups_part, .push = std.mem.asBytes(&dotp) });
    cmd.barrierComputeToCompute();
    const fp = FinishPush{ .partials = partials, .slot = @intFromEnum(slot) };
    try ks.finish.record(cmd, &.{ part, scal }, .{ .groups = .{ 1, 1, 1 }, .push = std.mem.asBytes(&fp) });
    cmd.barrierComputeToCompute();
}

fn submitWait(ctx: *molten.Context, cmd: *molten.CommandBuffer, fence: *molten.Fence) !void {
    try ctx.submit(.{ .cmd = cmd, .fence = fence });
    try fence.wait(5 * std.time.ns_per_s);
    try fence.reset();
    try cmd.reset();
}

// Reads only the control flag - never the residual. This is the single
// host-visible bit of loop state; all arithmetic stays on-device.
fn readDone(buf: *molten.Buffer(u32), alloc: std.mem.Allocator) !bool {
    const all = try buf.read(alloc);
    defer alloc.free(all);
    return all[0] != 0;
}
