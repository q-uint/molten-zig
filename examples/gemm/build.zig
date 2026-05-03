const std = @import("std");
const molten_build = @import("molten");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("molten", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("molten", dep.module("molten"));
    if (b.graph.environ_map.get("SDKROOT")) |sdk| {
        exe_mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
    }
    exe_mod.linkFramework("Accelerate", .{});

    const exe = b.addExecutable(.{ .name = "gemm", .root_module = exe_mod });
    b.installArtifact(exe);

    const kernel = molten_build.compileKernel(b, dep, "kernel", b.path("src/kernel.zig"), .{
        .variable_pointers = true,
        .optimize = .ReleaseFast,
    });
    const install_kernel_spv = b.addInstallFileWithDir(kernel.spv, .prefix, "kernel.spv");

    const glsl = b.addSystemCommand(&.{ "glslangValidator", "-V" });
    glsl.addFileArg(b.path("src/shader.comp"));
    glsl.addArg("-o");
    const raw_glsl_spv = glsl.addOutputFileArg("shader.spv");
    const glsl_spv = molten_build.validateSpv(b, raw_glsl_spv, "shader.spv");
    const install_glsl_spv = b.addInstallFileWithDir(glsl_spv, .prefix, "shader.spv");

    const run_zig = b.addRunArtifact(exe);
    run_zig.addFileArg(kernel.spv);
    const run_zig_step = b.step("run-zig", "Dispatch the Zig-derived kernel");
    run_zig_step.dependOn(&run_zig.step);

    const run_glsl = b.addRunArtifact(exe);
    run_glsl.addFileArg(glsl_spv);
    const run_glsl_step = b.step("run-glsl", "Dispatch the GLSL-derived kernel");
    run_glsl_step.dependOn(&run_glsl.step);

    const all = b.step("all", "Dispatch both kernels");
    all.dependOn(&run_zig.step);
    all.dependOn(&run_glsl.step);

    b.default_step.dependOn(&exe.step);
    b.default_step.dependOn(&install_kernel_spv.step);
    b.default_step.dependOn(&install_glsl_spv.step);
}
