// Specialised reduction kernel. T, op, tile, and workgroup_size are all
// comptime - each instantiation is a distinct SPIR-V module with the
// operation inlined, tile baked in, and LocalSize set per kernel.
//
// Each invocation reduces `tile` elements serially and writes one
// partial. workgroup_size only affects how the dispatch is partitioned;
// the kernel body doesn't read it (we don't have shared memory or
// barriers). The host folds partials.

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
    if (@typeInfo(T) == .float) {
        // FP add/mul reorder across invocations, so the same input under
        // different tile sizes produces different bit patterns. min/max
        // are exact.
        return op == .max or op == .min;
    }
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
                @as(T, (1 << (i.bits - 1)) - 1) // maxInt
            else
                ~@as(T, 0),
            .float => @as(T, 1.0) / @as(T, 0.0), // +inf
            else => @compileError("min requires int or float T"),
        },
        .max => switch (info) {
            .int => |i| if (i.signedness == .signed)
                @as(T, -(1 << (i.bits - 1))) // minInt
            else
                @as(T, 0),
            .float => @as(T, -1.0) / @as(T, 0.0), // -inf
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
    /// If false, refuses to instantiate non-associative reductions
    /// (e.g. f32 + add). Opt in to acknowledge the rounding drift.
    allow_non_associative: bool = false,
};

pub fn Reduce(
    comptime T: type,
    comptime op: Op,
    comptime tile: u32,
    comptime n: u32,
    comptime workgroup_size: u32,
    comptime opts: Options,
) type {
    if (tile == 0) @compileError("tile must be > 0");
    if (n == 0 or n % tile != 0) @compileError("n must be a positive multiple of tile");
    if (workgroup_size == 0) @compileError("workgroup_size must be > 0");
    if ((n / tile) % workgroup_size != 0)
        @compileError("workgroup_size must divide n/tile (the partials count)");
    if (!validBitwise(T, op)) @compileError("bitwise ops require integer T");
    if (!isAssociative(T, op) and !opts.allow_non_associative) {
        @compileError(
            "non-associative reduction (e.g. f32 + add) reorders operations" ++
                " across invocations and changes the result. Pass" ++
                " .allow_non_associative = true to acknowledge.",
        );
    }
    const partials = n / tile;

    return struct {
        const InBuf = extern struct { data: [n]T };
        const OutBuf = extern struct { data: [partials]T };

        const in_buf = @extern(*addrspace(.storage_buffer) InBuf, .{
            .name = "in_buf",
            .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
        });
        const out_buf = @extern(*addrspace(.storage_buffer) OutBuf, .{
            .name = "out_buf",
            .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } },
        });
        const global_invocation_id = @extern(
            *addrspace(.input) @Vector(3, u32),
            .{ .name = "global_invocation_id" },
        );

        pub const groups: [3]u32 = .{ partials / workgroup_size, 1, 1 };

        pub fn main() callconv(.spirv_kernel) void {
            @import("std").gpu.executionMode(main, .{
                .local_size = .{ .x = workgroup_size, .y = 1, .z = 1 },
            });

            const gid = global_invocation_id.*[0];
            if (gid >= partials) return;
            const base = gid * tile;

            var acc: T = identity(T, op);
            inline for (0..tile) |k| {
                acc = apply(T, op, acc, in_buf.*.data[base + k]);
            }
            out_buf.*.data[gid] = acc;
        }
    };
}
