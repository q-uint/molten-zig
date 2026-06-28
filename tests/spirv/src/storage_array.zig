//! Minimal repro: indexing an array field of a storage-buffer struct emits an
//! OpAccessChain whose result type is a different type-id than the struct
//! member it indexes into. The member array carries `ArrayStride` (buffer
//! layout); the access-chain references the undecorated array type, so the two
//! OpTypeArray ids differ and spirv-val rejects the module:
//!
//!   OpInBoundsAccessChain result type '%_arr_float_uint_256' does not match
//!   the type that results from indexing into the base '%_arr_float_uint_256_0'
//!   (The types must be the exact same Id)
//!
//! Reproduces with raw @extern too (no spritz code); see the PR for the
//! reduced form. Requires +variable_pointers.

const gpu = @import("gpu");

const N: u32 = 256;
const Buf = extern struct { data: [N]f32 };

const in_buf = gpu.storageBuffer(Buf, 0, 0, "in_buf");
const out_buf = gpu.storageBuffer(Buf, 0, 1, "out_buf");

pub fn entry() callconv(.{ .spirv_kernel = .{ .x = N, .y = 1, .z = 1 } }) void {
    const i = gpu.global_invocation_id[0];
    if (i >= N) return;
    out_buf.*.data[i] = in_buf.*.data[i] * 2.0;
}

comptime {
    @export(&entry, .{ .name = "main" });
}
