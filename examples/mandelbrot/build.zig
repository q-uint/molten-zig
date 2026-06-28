const std = @import("std");
const molten_build = @import("molten");

pub fn build(b: *std.Build) !void {
    const app = molten_build.standardExample(b, "mandelbrot", .{});

    const zig_k = molten_build.compileKernel(b, app.dep, "kernel", b.path("src/kernel.zig"), .{
        .optimize = .ReleaseFast,
    });

    molten_build.addRunAndBench(app, .{
        .name = "zig",
        .spv = zig_k.spv,
        .install_name = "kernel.spv",
    });
}
