// CPU reference conjugate-gradient solver for SPD systems, f32.
//
// This is the oracle the GPU CG loop is validated against: same f32
// arithmetic, same iteration recurrence (alpha/beta/residual), so a GPU
// run that diverges from this points at the backend, not at conditioning.
//
// Matvec is supplied as a callback so the same loop drives a dense test
// matrix here and an element-stiffness matvec later without change.

const std = @import("std");

pub const MatVec = *const fn (ctx: *anyopaque, x: []const f32, y: []f32) void;

pub const Result = struct {
    iters: u32,
    /// sqrt(r.r) at the iteration the loop stopped on.
    residual: f32,
    converged: bool,
};

pub const Options = struct {
    /// Stop when sqrt(r.r) <= tol * sqrt(b.b).
    tol: f32 = 1e-5,
    max_iters: u32 = 10_000,
};

/// Solve A x = b for SPD A. `x` is the initial guess in / solution out;
/// pass zeros for a cold start. Scratch slices r, p, ap must match len.
pub fn solve(
    matvec: MatVec,
    ctx: *anyopaque,
    b: []const f32,
    x: []f32,
    r: []f32,
    p: []f32,
    ap: []f32,
    opts: Options,
) Result {
    const n = b.len;
    std.debug.assert(x.len == n and r.len == n and p.len == n and ap.len == n);

    // r = b - A x ; p = r
    matvec(ctx, x, ap);
    for (0..n) |i| {
        r[i] = b[i] - ap[i];
        p[i] = r[i];
    }

    var rs_old = dot(r, r);
    const bnorm = @sqrt(dot(b, b));
    const stop = opts.tol * (if (bnorm > 0) bnorm else 1.0);

    if (@sqrt(rs_old) <= stop) {
        return .{ .iters = 0, .residual = @sqrt(rs_old), .converged = true };
    }

    var iter: u32 = 0;
    while (iter < opts.max_iters) : (iter += 1) {
        matvec(ctx, p, ap);
        const pap = dot(p, ap);
        const alpha = rs_old / pap;
        for (0..n) |i| {
            x[i] += alpha * p[i];
            r[i] -= alpha * ap[i];
        }
        const rs_new = dot(r, r);
        if (@sqrt(rs_new) <= stop) {
            return .{ .iters = iter + 1, .residual = @sqrt(rs_new), .converged = true };
        }
        const beta = rs_new / rs_old;
        for (0..n) |i| p[i] = r[i] + beta * p[i];
        rs_old = rs_new;
    }

    return .{ .iters = iter, .residual = @sqrt(rs_old), .converged = false };
}

fn dot(a: []const f32, b: []const f32) f32 {
    var s: f32 = 0;
    for (a, b) |x, y| s += x * y;
    return s;
}

// 1D Poisson: tridiagonal K with diag 2, offdiag -1 (the discrete
// Laplacian, SPD). Dirichlet at both ends folded into b.
const Poisson1D = struct {
    n: usize,
    fn apply(ctx: *anyopaque, x: []const f32, y: []f32) void {
        const self: *const Poisson1D = @ptrCast(@alignCast(ctx));
        const n = self.n;
        for (0..n) |i| {
            var v: f32 = 2.0 * x[i];
            if (i > 0) v -= x[i - 1];
            if (i + 1 < n) v -= x[i + 1];
            y[i] = v;
        }
    }
};

test "CG solves 1D Poisson with constant load to known parabola" {
    const alloc = std.testing.allocator;
    const n: usize = 64;

    // K u = f with f = h^2 (constant 1). On a unit grid the discrete
    // problem -u'' = 1, u(0)=u(1)=0 has exact nodal values
    //   u_i = 0.5 * (i+1) * (n - i) ... derived from the tridiagonal solve.
    // We pick the analytic continuous solution u(t) = 0.5 t (1 - t) sampled
    // at interior nodes and verify CG recovers it from K u = f.
    var sys = Poisson1D{ .n = n };

    const b = try alloc.alloc(f32, n);
    defer alloc.free(b);
    const x = try alloc.alloc(f32, n);
    defer alloc.free(x);
    const r = try alloc.alloc(f32, n);
    defer alloc.free(r);
    const p = try alloc.alloc(f32, n);
    defer alloc.free(p);
    const ap = try alloc.alloc(f32, n);
    defer alloc.free(ap);

    const h: f32 = 1.0 / @as(f32, @floatFromInt(n + 1));
    // exact: u(t) = 0.5 t (1 - t); -u'' = 1 so K u = h^2 * 1 at each node.
    const exact = try alloc.alloc(f32, n);
    defer alloc.free(exact);
    for (0..n) |i| {
        const t = @as(f32, @floatFromInt(i + 1)) * h;
        exact[i] = 0.5 * t * (1.0 - t);
        b[i] = h * h; // f = 1 scaled by h^2
        x[i] = 0;
    }

    const res = solve(Poisson1D.apply, &sys, b, x, r, p, ap, .{ .tol = 1e-6, .max_iters = 1000 });

    try std.testing.expect(res.converged);
    // 1D Poisson CG converges in <= n iterations exactly (Krylov),
    // typically far fewer here.
    try std.testing.expect(res.iters <= n);

    // Discretization error is O(h^2); the solver should hit the exact
    // discrete solution, which sits within a few h^2 of the continuous one.
    var max_err: f32 = 0;
    for (0..n) |i| max_err = @max(max_err, @abs(x[i] - exact[i]));
    try std.testing.expect(max_err < 1e-3);
}

test "CG on cold zero-rhs returns immediately" {
    var sys = Poisson1D{ .n = 8 };
    const zeros = [_]f32{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var b = zeros;
    var x = zeros;
    var r = zeros;
    var p = zeros;
    var ap = zeros;
    const res = solve(Poisson1D.apply, &sys, &b, &x, &r, &p, &ap, .{});
    try std.testing.expect(res.converged);
    try std.testing.expectEqual(@as(u32, 0), res.iters);
}
