// Usage: ./vector_multiply <kernel.spv>

const std = @import("std");
const common = @import("common");

const N: u32 = 1024;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    const args = try common.Args.parse(init, alloc);
    defer args.deinit(alloc);

    var input: [N]f32 = undefined;
    var expected: [N]f32 = undefined;
    for (0..N) |i| {
        input[i] = @floatFromInt(i);
        expected[i] = input[i] * 2.0;
    }

    try common.run(f32, init, alloc, args.spv_path, .{
        .input = &input,
        .expected = &expected,
        .groups = .{ N, 1, 1 },
        .label = "vector_multiply",
    });
}
