const gpu = @import("gpu");

const Buf = extern struct { data: @SpirvType(.{ .runtime_array = u32 }) };
const counter = @extern(*addrspace(.storage_buffer) Buf, .{
    .name = "counter",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
});

pub fn entry() callconv(.{ .spirv_kernel = .{ .x = 256, .y = 1, .z = 1 } }) void {
    _ = gpu.atomicAdd(u32, &(&counter.data)[0], 1);
}

comptime {
    @export(&entry, .{ .name = "main" });
}
