const reduce = @import("reduce.zig");

pub const Kernel = reduce.Reduce(u32, .add, 64, .{});

comptime {
    @export(&Kernel.main, .{ .name = "main" });
}
