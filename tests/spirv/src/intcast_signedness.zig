//! Minimal repro: a same-bit-width @intCast that flips signedness (u32 -> i32)
//! is lowered as a type "pun" with no OpBitcast, so the original unsigned
//! result-id flows into a signed (i32) destination. When that i32 is passed to
//! a helper it is stored into an i32 Function variable and spirv-val rejects:
//!
//!   OpStore Pointer <id>'s type does not match Object <id>'s type
//!
//! The signed value is needed for negative neighbour offsets at the edges of a
//! stencil; here `at` takes i32 coordinates and clamps them.

const gpu = @import("gpu");

const N: u32 = 256;
const Buf = extern struct { data: [N]f32 };

const in_buf = gpu.storageBuffer(Buf, 0, 0, "in_buf");
const out_buf = gpu.storageBuffer(Buf, 0, 1, "out_buf");

fn at(x: i32) f32 {
    const cx: u32 = @intCast(@max(0, @min(@as(i32, N) - 1, x)));
    return in_buf.*.data[cx];
}

pub fn entry() callconv(.{ .spirv_kernel = .{ .x = N, .y = 1, .z = 1 } }) void {
    const u = gpu.global_invocation_id[0];
    if (u >= N) return;
    const s: i32 = @intCast(u);
    out_buf.*.data[u] = at(s - 1) + at(s) + at(s + 1);
}

comptime {
    @export(&entry, .{ .name = "main" });
}
