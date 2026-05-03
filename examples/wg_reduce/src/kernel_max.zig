const wg_reduce = @import("wg_reduce");

pub const Kernel = wg_reduce.WgReduce(i32, .max, 2048, 256, .{});

comptime {
    @export(&Kernel.main, .{ .name = "main" });
}
