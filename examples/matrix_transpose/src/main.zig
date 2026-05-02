// Usage: ./matrix_transpose <kernel.spv> [zig|glsl]
//
// The second arg picks the dispatch shape: the Zig kernel uses LocalSize
// 1 1 1 so we dispatch (N, N, 1); the GLSL kernel uses an 8x8 tile so we
// dispatch (N/TILE, N/TILE, 1).

const std = @import("std");
const common = @import("common");

const N: u32 = 64;
const TILE: u32 = 8;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    const args = try common.Args.parse(init, alloc);
    defer args.deinit(alloc);
    if (args.rest.len != 1) return error.BadArgs;
    const kind = args.rest[0];

    const groups: [3]u32 = if (std.mem.eql(u8, kind, "zig"))
        .{ N, N, 1 }
    else if (std.mem.eql(u8, kind, "glsl"))
        .{ N / TILE, N / TILE, 1 }
    else
        return error.BadArgs;

    var input: [N * N]f32 = undefined;
    var expected: [N * N]f32 = undefined;
    for (0..N) |y| for (0..N) |x| {
        input[y * N + x] = @floatFromInt(y * N + x);
    };
    for (0..N) |y| for (0..N) |x| {
        expected[y * N + x] = input[x * N + y];
    };

    try common.run(f32, init, alloc, args.spv_path, .{
        .input = &input,
        .expected = &expected,
        .groups = groups,
        .label = "matrix_transpose",
    });
}
