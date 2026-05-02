// Workgroup-local tree reduction. Each kernel reduces the entire input
// in one workgroup: every lane folds `tile = n / workgroup_size` inputs
// serially into shared scratch, then a barrier-synchronised tree fold
// over the workgroup writes one output. T, op, n, and workgroup_size
// are all comptime - each instantiation is its own SPIR-V module.

const gpu = @import("std").gpu;

pub const Op = enum {
    add,
    mul,
    max,
    min,
    bitwise_or,
    bitwise_and,
    bitwise_xor,
};

fn isAssociative(comptime T: type, comptime op: Op) bool {
    if (@typeInfo(T) == .float) return op == .max or op == .min;
    return true;
}

fn validBitwise(comptime T: type, comptime op: Op) bool {
    const is_bitwise = op == .bitwise_or or op == .bitwise_and or op == .bitwise_xor;
    if (!is_bitwise) return true;
    return @typeInfo(T) == .int;
}

fn identity(comptime T: type, comptime op: Op) T {
    const info = @typeInfo(T);
    return switch (op) {
        .add, .bitwise_or, .bitwise_xor => 0,
        .mul => 1,
        .bitwise_and => switch (info) {
            .int => ~@as(T, 0),
            else => @compileError("bitwise_and requires integer T"),
        },
        .min => switch (info) {
            .int => |i| if (i.signedness == .signed)
                @as(T, (1 << (i.bits - 1)) - 1)
            else
                ~@as(T, 0),
            .float => @as(T, 1.0) / @as(T, 0.0),
            else => @compileError("min requires int or float T"),
        },
        .max => switch (info) {
            .int => |i| if (i.signedness == .signed)
                @as(T, -(1 << (i.bits - 1)))
            else
                @as(T, 0),
            .float => @as(T, -1.0) / @as(T, 0.0),
            else => @compileError("max requires int or float T"),
        },
    };
}

fn apply(comptime T: type, comptime op: Op, a: T, b: T) T {
    return switch (op) {
        .add => a + b,
        .mul => a * b,
        .max => @max(a, b),
        .min => @min(a, b),
        .bitwise_or => a | b,
        .bitwise_and => a & b,
        .bitwise_xor => a ^ b,
    };
}

pub const Options = struct {
    allow_non_associative: bool = false,
};

pub fn WgReduce(
    comptime T: type,
    comptime op: Op,
    comptime n: u32,
    comptime workgroup_size: u32,
    comptime opts: Options,
) type {
    if (n == 0 or workgroup_size == 0) @compileError("n and workgroup_size must be > 0");
    if (n % workgroup_size != 0) @compileError("workgroup_size must divide n");
    if (workgroup_size & (workgroup_size - 1) != 0)
        @compileError("workgroup_size must be a power of two for the tree fold");
    if (!validBitwise(T, op)) @compileError("bitwise ops require integer T");
    if (!isAssociative(T, op) and !opts.allow_non_associative) {
        @compileError(
            "non-associative reduction (e.g. f32 + add) reorders operations" ++
                " across invocations and changes the result. Pass" ++
                " .allow_non_associative = true to acknowledge.",
        );
    }
    const tile = n / workgroup_size;

    return struct {
        const InBuf = extern struct { data: [n]T };
        const OutBuf = extern struct { data: [1]T };

        const in_buf = @extern(*addrspace(.storage_buffer) InBuf, .{
            .name = "in_buf",
            .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
        });
        const out_buf = @extern(*addrspace(.storage_buffer) OutBuf, .{
            .name = "out_buf",
            .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } },
        });

        var scratch: [workgroup_size]T addrspace(.shared) = undefined;

        pub const groups: [3]u32 = .{ 1, 1, 1 };

        pub fn main() callconv(.spirv_kernel) void {
            gpu.executionMode(main, .{
                .local_size = .{ .x = workgroup_size, .y = 1, .z = 1 },
            });

            const lid = gpu.local_invocation_id[0];
            const base = lid * tile;

            var acc: T = identity(T, op);
            inline for (0..tile) |k| {
                acc = apply(T, op, acc, in_buf.*.data[base + k]);
            }
            scratch[lid] = acc;
            gpu.workgroupBarrier();

            var stride: u32 = workgroup_size / 2;
            while (stride > 0) : (stride /= 2) {
                if (lid < stride) {
                    scratch[lid] = apply(T, op, scratch[lid], scratch[lid + stride]);
                }
                gpu.workgroupBarrier();
            }

            if (lid == 0) out_buf.*.data[0] = scratch[0];
        }
    };
}
