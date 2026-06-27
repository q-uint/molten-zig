//! Runtime-sized storage buffers via the upstream @SpirvType builtin: the
//! field lowers to OpTypeRuntimeArray with ArrayStride, indexed through a
//! pointer to the array field. Requires +variable_pointers.

const gpu = @import("gpu");

const Buf = extern struct { data: @SpirvType(.{ .runtime_array = f32 }) };

const in_buf = @extern(*addrspace(.storage_buffer) const Buf, .{
    .name = "in_buf",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
});
const out_buf = @extern(*addrspace(.storage_buffer) Buf, .{
    .name = "out_buf",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } },
});

pub fn entry() callconv(.{ .spirv_kernel = .{ .x = 256, .y = 1, .z = 1 } }) void {
    const i = gpu.global_invocation_id[0];
    (&out_buf.data)[i] = (&in_buf.data)[i] * 2.0;
}

comptime {
    @export(&entry, .{ .name = "main" });
}
