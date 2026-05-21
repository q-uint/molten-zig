const std = @import("std");
const molten_build = @import("molten");

pub fn build(b: *std.Build) !void {
    const app = molten_build.standardExample(b, "matrix_transpose", .{});

    const zig_k = molten_build.compileKernel(b, app.dep, "kernel", b.path("src/kernel.zig"), .{});
    const glsl_k = molten_build.compileGlsl(b, "shader", b.path("src/shader.comp"), &.{});

    molten_build.addRunAndBench(app, .{
        .name = "zig",
        .spv = zig_k.spv,
        .install_name = "kernel.spv",
        .extra_args = &.{"zig"},
    });
    molten_build.addRunAndBench(app, .{
        .name = "glsl",
        .spv = glsl_k.spv,
        .install_name = "shader.spv",
        .extra_args = &.{"glsl"},
    });
}
