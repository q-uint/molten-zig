const reduce = @import("reduce.zig");

pub const Kernel = reduce.Reduce(i32, .max, 64, .{});

comptime {
    @export(&Kernel.main, .{ .name = "main" });
}
