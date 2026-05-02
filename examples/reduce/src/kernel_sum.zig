// One of two instantiations of the same Reduce factory. The diff
// against kernel_max.zig is two values: T and op.
const reduce = @import("reduce.zig");

pub const Kernel = reduce.Reduce(u32, .add, 64, 1 << 14, 64, .{});

comptime {
    @export(&Kernel.main, .{ .name = "main" });
}
