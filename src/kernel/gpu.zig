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
