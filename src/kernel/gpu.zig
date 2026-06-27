//! Kernel-side SPIR-V helpers: buffer/builtin declarations layered over the
//! compiler's `@extern` + addrspace support. Imported as `gpu` inside kernels.
//! Barrier primitives live in std.spirv; re-exported here so kernels need one
//! import. Workgroup size is set via the entry point's calling convention,
//! e.g. `callconv(.{ .spirv_kernel = .{ .x = 64, .y = 1, .z = 1 } })`.

const spirv = @import("std").spirv;

pub const Scope = spirv.Scope;
pub const MemorySemantics = spirv.MemorySemantics;
pub const controlBarrier = spirv.controlBarrier;
pub const memoryBarrier = spirv.memoryBarrier;
pub const workgroupBarrier = spirv.workgroupBarrier;

pub extern const num_workgroups: @Vector(3, u32) addrspace(.input);
pub extern const workgroup_id: @Vector(3, u32) addrspace(.input);
pub extern const local_invocation_id: @Vector(3, u32) addrspace(.input);
pub extern const global_invocation_id: @Vector(3, u32) addrspace(.input);

pub inline fn storageBuffer(
    comptime T: type,
    comptime set: u32,
    comptime bind: u32,
    comptime name: [:0]const u8,
) *addrspace(.storage_buffer) T {
    return @extern(*addrspace(.storage_buffer) T, .{
        .name = name,
        .decoration = .{ .descriptor = .{ .set = set, .binding = bind } },
    });
}

pub inline fn uniformBuffer(
    comptime T: type,
    comptime set: u32,
    comptime bind: u32,
    comptime name: [:0]const u8,
) *addrspace(.uniform) T {
    return @extern(*addrspace(.uniform) T, .{
        .name = name,
        .decoration = .{ .descriptor = .{ .set = set, .binding = bind } },
    });
}

pub inline fn pushConstant(
    comptime T: type,
    comptime name: [:0]const u8,
) *addrspace(.push_constant) T {
    return @extern(*addrspace(.push_constant) T, .{ .name = name });
}

// Atomics. The self-hosted SPIR-V backend has no @atomicRmw lowering, so these
// emit the OpAtomic* instructions directly via inline asm. ptr must point into
// a buffer addrspace; scope/semantics default to device-visible.
const atomic_scope: u32 = @intFromEnum(Scope.device);
const atomic_sem: u32 = @bitCast(MemorySemantics.none);

pub inline fn atomicAdd(comptime T: type, ptr: *addrspace(.storage_buffer) T, value: T) T {
    return asm volatile (
        \\%res = OpAtomicIAdd %ty %ptr %scope %sem %val
        : [res] "" (-> T),
        : [ty] "t" (T),
          [ptr] "" (ptr),
          [scope] "" (atomic_scope),
          [sem] "" (atomic_sem),
          [val] "" (value),
    );
}

pub inline fn atomicMax(comptime T: type, ptr: *addrspace(.storage_buffer) T, value: T) T {
    const op = if (@typeInfo(T).int.signedness == .signed) "OpAtomicSMax" else "OpAtomicUMax";
    return asm volatile ("%res = " ++ op ++ " %ty %ptr %scope %sem %val"
        : [res] "" (-> T),
        : [ty] "t" (T),
          [ptr] "" (ptr),
          [scope] "" (atomic_scope),
          [sem] "" (atomic_sem),
          [val] "" (value),
    );
}

pub inline fn atomicMin(comptime T: type, ptr: *addrspace(.storage_buffer) T, value: T) T {
    const op = if (@typeInfo(T).int.signedness == .signed) "OpAtomicSMin" else "OpAtomicUMin";
    return asm volatile ("%res = " ++ op ++ " %ty %ptr %scope %sem %val"
        : [res] "" (-> T),
        : [ty] "t" (T),
          [ptr] "" (ptr),
          [scope] "" (atomic_scope),
          [sem] "" (atomic_sem),
          [val] "" (value),
    );
}

pub inline fn atomicExchange(comptime T: type, ptr: *addrspace(.storage_buffer) T, value: T) T {
    return asm volatile (
        \\%res = OpAtomicExchange %ty %ptr %scope %sem %val
        : [res] "" (-> T),
        : [ty] "t" (T),
          [ptr] "" (ptr),
          [scope] "" (atomic_scope),
          [sem] "" (atomic_sem),
          [val] "" (value),
    );
}
