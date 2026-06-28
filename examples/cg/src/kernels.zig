// GPU-resident CG kernels. Scalars (alpha, beta) live in storage buffers and
// are read by the vector-update dispatches, so the iteration never round-trips
// to the host - only the final x is read back.
//
// Buffers are f32 runtime arrays except the scalar buffers, which hold a small
// fixed set of slots (see ScalarSlot). The host loop in main.zig records these
// in sequence with compute-to-compute barriers between dependent dispatches.

const gpu = @import("gpu");

const Vec = extern struct { data: @SpirvType(.{ .runtime_array = f32 }) };

// Scalar buffer layout, shared by the reduction-finish and update kernels.
// Single buffer, fixed slots, so one binding carries all loop scalars.
pub const ScalarSlot = enum(u32) {
    rs_old = 0, // r.r from the previous iteration
    rs_new = 1, // r.r this iteration
    pap = 2, // p.(A p)
    alpha = 3, // rs_old / pap
    beta = 4, // rs_new / rs_old
    stop = 5, // tol^2 * (b.b); compared against rs_new (both squared norms)
    _count = 6,
};

const WG: u32 = 64;

// Single source of truth for kernel set, order, and count. build.zig compiles
// one spv per entry (the tag name maps to the struct via @field); the host
// loads spvs in this order and indexes them by tag. Add a kernel in one place.
pub const KernelId = enum {
    matvec,
    dot,
    finish_dot,
    compute_alpha,
    compute_beta,
    axpy_alpha,
    update_p,
    init_stop,
    check_converged,

    pub const count = @typeInfo(KernelId).@"enum".field_names.len;
};

const Push = extern struct { n: u32, tile: u32 };

fn vec(comptime set: u32, comptime bind: u32, comptime name: [:0]const u8) *addrspace(.storage_buffer) Vec {
    return @extern(*addrspace(.storage_buffer) Vec, .{ .name = name, .decoration = .{ .descriptor = .{ .set = set, .binding = bind } } });
}

// dot: partial sums of a.b over tiles. Output one partial per workgroup-row.
// Non-associative f32 add across tiles; the host reference tolerates this.
pub const Dot = struct {
    const a = @extern(*addrspace(.storage_buffer) const Vec, .{ .name = "a", .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } } });
    const b = @extern(*addrspace(.storage_buffer) const Vec, .{ .name = "b", .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } } });
    const out = vec(0, 2, "out");
    const push = gpu.pushConstant(Push, "push");

    pub fn main() callconv(.{ .spirv_kernel = .{ .x = WG, .y = 1, .z = 1 } }) void {
        const n = push.*.n;
        const tile = push.*.tile;
        const partials = n / tile;
        const gid = gpu.global_invocation_id[0];
        if (gid >= partials) return;
        const base = gid * tile;
        var acc: f32 = 0;
        var k: u32 = 0;
        while (k < tile) : (k += 1) acc += (&a.data)[base + k] * (&b.data)[base + k];
        (&out.data)[gid] = acc;
    }
};

// finishDot: sum the partials into a scalar slot. 1 thread.
// `slot` chooses where the result lands (rs_old / rs_new / pap).
const FinishPush = extern struct { partials: u32, slot: u32 };

pub const FinishDot = struct {
    const partials_buf = @extern(*addrspace(.storage_buffer) const Vec, .{ .name = "partials", .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } } });
    const scalars = vec(0, 1, "scalars");
    const push = gpu.pushConstant(FinishPush, "push");

    pub fn main() callconv(.{ .spirv_kernel = .{ .x = 1, .y = 1, .z = 1 } }) void {
        if (gpu.global_invocation_id[0] != 0) return;
        const m = push.*.partials;
        var acc: f32 = 0;
        var k: u32 = 0;
        while (k < m) : (k += 1) acc += (&partials_buf.data)[k];
        (&scalars.data)[push.*.slot] = acc;
    }
};

// computeAlpha: alpha = rs_old / pap. 1 thread.
pub const ComputeAlpha = struct {
    const scalars = vec(0, 0, "scalars");
    pub fn main() callconv(.{ .spirv_kernel = .{ .x = 1, .y = 1, .z = 1 } }) void {
        if (gpu.global_invocation_id[0] != 0) return;
        const s = &scalars.data;
        s[@intFromEnum(ScalarSlot.alpha)] = s[@intFromEnum(ScalarSlot.rs_old)] / s[@intFromEnum(ScalarSlot.pap)];
    }
};

// computeBeta: beta = rs_new / rs_old, then rs_old <- rs_new. 1 thread.
// Order matters: read rs_old before overwriting it.
pub const ComputeBeta = struct {
    const scalars = vec(0, 0, "scalars");
    pub fn main() callconv(.{ .spirv_kernel = .{ .x = 1, .y = 1, .z = 1 } }) void {
        if (gpu.global_invocation_id[0] != 0) return;
        const s = &scalars.data;
        const rs_new = s[@intFromEnum(ScalarSlot.rs_new)];
        s[@intFromEnum(ScalarSlot.beta)] = rs_new / s[@intFromEnum(ScalarSlot.rs_old)];
        s[@intFromEnum(ScalarSlot.rs_old)] = rs_new;
    }
};

// initStop: stop = tol^2 * rs_old, computed once after the cold-start
// rs_old = b.b lands. Comparing squared norms keeps the loop sqrt-free.
const TolPush = extern struct { tol2: f32 };

pub const InitStop = struct {
    const scalars = vec(0, 0, "scalars");
    const push = gpu.pushConstant(TolPush, "push");
    pub fn main() callconv(.{ .spirv_kernel = .{ .x = 1, .y = 1, .z = 1 } }) void {
        if (gpu.global_invocation_id[0] != 0) return;
        const s = &scalars.data;
        s[@intFromEnum(ScalarSlot.stop)] = push.*.tol2 * s[@intFromEnum(ScalarSlot.rs_old)];
    }
};

// checkConverged: done = (rs_new <= stop). The host polls done only to
// decide whether to keep submitting; it never reads the residual itself.
const Flag = extern struct { data: @SpirvType(.{ .runtime_array = u32 }) };

pub const CheckConverged = struct {
    const scalars = @extern(*addrspace(.storage_buffer) const Vec, .{ .name = "scalars", .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } } });
    const done = @extern(*addrspace(.storage_buffer) Flag, .{ .name = "done", .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } } });
    pub fn main() callconv(.{ .spirv_kernel = .{ .x = 1, .y = 1, .z = 1 } }) void {
        if (gpu.global_invocation_id[0] != 0) return;
        const s = &scalars.data;
        const converged = s[@intFromEnum(ScalarSlot.rs_new)] <= s[@intFromEnum(ScalarSlot.stop)];
        (&done.data)[0] = if (converged) 1 else 0;
    }
};

// axpyAlpha: y += sign * alpha * v, reading alpha from the scalar buffer.
// sign in push lets one kernel serve both x += alpha p and r -= alpha Ap.
const AxpyPush = extern struct { n: u32, sign: f32 };

pub const AxpyAlpha = struct {
    const y = vec(0, 0, "y");
    const v = @extern(*addrspace(.storage_buffer) const Vec, .{ .name = "v", .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } } });
    const scalars = @extern(*addrspace(.storage_buffer) const Vec, .{ .name = "scalars", .decoration = .{ .descriptor = .{ .set = 0, .binding = 2 } } });
    const push = gpu.pushConstant(AxpyPush, "push");

    pub fn main() callconv(.{ .spirv_kernel = .{ .x = WG, .y = 1, .z = 1 } }) void {
        const i = gpu.global_invocation_id[0];
        if (i >= push.*.n) return;
        const alpha = (&scalars.data)[@intFromEnum(ScalarSlot.alpha)];
        (&y.data)[i] += push.*.sign * alpha * (&v.data)[i];
    }
};

// updateP: p = r + beta * p, beta from the scalar buffer.
const NPush = extern struct { n: u32 };

pub const UpdateP = struct {
    const p = vec(0, 0, "p");
    const r = @extern(*addrspace(.storage_buffer) const Vec, .{ .name = "r", .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } } });
    const scalars = @extern(*addrspace(.storage_buffer) const Vec, .{ .name = "scalars", .decoration = .{ .descriptor = .{ .set = 0, .binding = 2 } } });
    const push = gpu.pushConstant(NPush, "push");

    pub fn main() callconv(.{ .spirv_kernel = .{ .x = WG, .y = 1, .z = 1 } }) void {
        const i = gpu.global_invocation_id[0];
        if (i >= push.*.n) return;
        const beta = (&scalars.data)[@intFromEnum(ScalarSlot.beta)];
        (&p.data)[i] = (&r.data)[i] + beta * (&p.data)[i];
    }
};

// matvec: y = A x for the 1D Poisson tridiagonal (diag 2, offdiag -1).
// Dense stand-in for the eventual element-stiffness matvec; same loop shape.
pub const Matvec = struct {
    const x = @extern(*addrspace(.storage_buffer) const Vec, .{ .name = "x", .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } } });
    const y = vec(0, 1, "y");
    const push = gpu.pushConstant(NPush, "push");

    pub fn main() callconv(.{ .spirv_kernel = .{ .x = WG, .y = 1, .z = 1 } }) void {
        const n = push.*.n;
        const i = gpu.global_invocation_id[0];
        if (i >= n) return;
        var acc: f32 = 2.0 * (&x.data)[i];
        if (i > 0) acc -= (&x.data)[i - 1];
        if (i + 1 < n) acc -= (&x.data)[i + 1];
        (&y.data)[i] = acc;
    }
};
