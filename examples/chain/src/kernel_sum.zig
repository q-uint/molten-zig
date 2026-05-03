const reduce = @import("reduce");

pub const Kernel = reduce.Reduce(u32, .add, 64, .{});

comptime {
    @export(&Kernel.main, .{ .name = "main" });
}
