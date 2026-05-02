const std = @import("std");
const molten_build = @import("molten");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("molten", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_common = b.dependency("common", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("common", dep_common.module("common"));

    const exe = b.addExecutable(.{ .name = "matrix_transpose", .root_module = exe_mod });
    b.installArtifact(exe);

    const kernel = molten_build.compileKernel(b, dep, "kernel", b.path("src/kernel.zig"));
    const install_kernel_spv = b.addInstallFileWithDir(kernel.spv, .prefix, "kernel.spv");

    const glsl = b.addSystemCommand(&.{ "glslangValidator", "-V" });
    glsl.addFileArg(b.path("src/shader.comp"));
    glsl.addArg("-o");
    const glsl_spv = glsl.addOutputFileArg("shader.spv");
    const val_glsl = b.addSystemCommand(&.{"spirv-val"});
    val_glsl.addFileArg(glsl_spv);
    const install_glsl_spv = b.addInstallFileWithDir(glsl_spv, .prefix, "shader.spv");

    const validate_step = b.step("validate", "Run spirv-val on both kernels");
    validate_step.dependOn(kernel.validate);
    validate_step.dependOn(&val_glsl.step);

    const run_zig = b.addRunArtifact(exe);
    run_zig.addFileArg(kernel.spv);
    run_zig.addArg("zig");
    const run_zig_step = b.step("run-zig", "Dispatch the Zig-derived kernel");
    run_zig_step.dependOn(&run_zig.step);

    const run_glsl = b.addRunArtifact(exe);
    run_glsl.addFileArg(glsl_spv);
    run_glsl.addArg("glsl");
    const run_glsl_step = b.step("run-glsl", "Dispatch the GLSL-derived kernel");
    run_glsl_step.dependOn(&run_glsl.step);

    const all = b.step("all", "Validate and dispatch both kernels");
    all.dependOn(validate_step);
    all.dependOn(&run_zig.step);
    all.dependOn(&run_glsl.step);

    b.default_step.dependOn(&exe.step);
    b.default_step.dependOn(&install_kernel_spv.step);
    b.default_step.dependOn(&install_glsl_spv.step);
}
