//! Atomics via inline OpAtomic* asm in gpu.zig (the backend has no @atomicRmw
//! lowering). Every lane folds into shared device-scope counters.

const gpu = @import("gpu");

const Buf = extern struct { data: @SpirvType(.{ .runtime_array = u32 }) };
const SBuf = extern struct { data: @SpirvType(.{ .runtime_array = i32 }) };

const usum = @extern(*addrspace(.storage_buffer) Buf, .{ .name = "usum", .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } } });
const umax = @extern(*addrspace(.storage_buffer) Buf, .{ .name = "umax", .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } } });
const smin = @extern(*addrspace(.storage_buffer) SBuf, .{ .name = "smin", .decoration = .{ .descriptor = .{ .set = 0, .binding = 2 } } });
const xchg = @extern(*addrspace(.storage_buffer) Buf, .{ .name = "xchg", .decoration = .{ .descriptor = .{ .set = 0, .binding = 3 } } });

pub fn entry() callconv(.{ .spirv_kernel = .{ .x = 64, .y = 1, .z = 1 } }) void {
    const i = gpu.global_invocation_id[0];
    const si: i32 = @bitCast(i);
    _ = gpu.atomicAdd(u32, &(&usum.data)[0], i);
    _ = gpu.atomicMax(u32, &(&umax.data)[0], i);
    _ = gpu.atomicMin(i32, &(&smin.data)[0], si);
    _ = gpu.atomicExchange(u32, &(&xchg.data)[0], i);
}

comptime {
    @export(&entry, .{ .name = "main" });
}
