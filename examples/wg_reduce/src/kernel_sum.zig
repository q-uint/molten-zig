// One of two instantiations. The diff against kernel_max.zig is two
// values: T and op.
const wg_reduce = @import("wg_reduce.zig");

pub const Kernel = wg_reduce.WgReduce(u32, .add, 2048, 256, .{});

comptime {
    @export(&Kernel.main, .{ .name = "main" });
}
