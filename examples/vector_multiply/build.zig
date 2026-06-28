const std = @import("std");
const spritz_build = @import("spritz");

pub fn build(b: *std.Build) !void {
    const app = spritz_build.standardExample(b, "vector_multiply");

    const zig_k = spritz_build.compileKernel(b, app.dep, "kernel", b.path("src/kernel.zig"), .{});
    const glsl_k = spritz_build.compileGlsl(b, app.dep, "shader", b.path("src/shader.comp"), &.{});

    spritz_build.addRunAndBench(app, .{ .name = "zig", .spv = zig_k.spv, .install_name = "kernel.spv" });
    spritz_build.addRunAndBench(app, .{ .name = "glsl", .spv = glsl_k.spv, .install_name = "shader.spv" });
}
