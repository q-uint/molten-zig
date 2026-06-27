//! Minimal repro (sibling of storage_array): indexing a runtime-sized storage
//! buffer emits an OpPtrAccessChain whose base array type is NOT decorated with
//! ArrayStride, so spirv-val rejects it:
//!
//!   OpPtrAccessChain must have a Base whose type is decorated with ArrayStride
//!   or ArrayStrideIdEXT
//!
//! Same backend bug family as storage_array.zig (ArrayStride decoration in
//! src/codegen/spirv), different facet: here the stride is missing entirely
//! rather than landing on a duplicate type id. Requires +variable_pointers.

const gpu = @import("gpu");

const in_buf = gpu.runtimeArray(f32, 0, 0, "in_buf");
const out_buf = gpu.runtimeArray(f32, 0, 1, "out_buf");

pub fn entry() callconv(.{ .spirv_kernel = .{ .x = 256, .y = 1, .z = 1 } }) void {
    const i = gpu.global_invocation_id[0];
    out_buf.*.data[i] = in_buf.*.data[i] * 2.0;
}

comptime {
    @export(&entry, .{ .name = "main" });
}
