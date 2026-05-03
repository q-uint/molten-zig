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

pub const Push = extern struct { n: u32, tile: u32 };

pub const Options = struct {
    allow_non_associative: bool = false,
};

pub fn Reduce(
    comptime T: type,
    comptime op: Op,
    comptime workgroup_size: u32,
    comptime opts: Options,
) type {
    if (workgroup_size == 0) @compileError("workgroup_size must be > 0");
    if (!validBitwise(T, op)) @compileError("bitwise ops require integer T");
    if (!isAssociative(T, op) and !opts.allow_non_associative) {
        @compileError(
            "non-associative reduction (e.g. f32 + add) reorders operations" ++
                " across invocations and changes the result. Pass" ++
                " .allow_non_associative = true to acknowledge.",
        );
    }

    return struct {
        const in_buf = gpu.runtimeArray(T, 0, 0, "in_buf");
        const out_buf = gpu.runtimeArray(T, 0, 1, "out_buf");
        const push = gpu.pushConstant(Push, "push");

        pub fn main() callconv(.spirv_kernel) void {
            gpu.executionMode(main, .{
                .local_size = .{ .x = workgroup_size, .y = 1, .z = 1 },
            });

            const n = push.*.n;
            const tile = push.*.tile;
            const partials = n / tile;
            const gid = gpu.global_invocation_id[0];
            if (gid >= partials) return;
            const base = gid * tile;

            var acc: T = identity(T, op);
            var k: u32 = 0;
            while (k < tile) : (k += 1) {
                acc = apply(T, op, acc, in_buf.*.data[base + k]);
            }
            out_buf.*.data[gid] = acc;
        }
    };
}
