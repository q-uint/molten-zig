const std = @import("std");
const spritz_build = @import("spritz");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("spritz", .{
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
    exe_mod.addImport("spritz", dep.module("spritz"));

    const exe = b.addExecutable(.{ .name = "chain", .root_module = exe_mod });
    b.installArtifact(exe);

    const reduce_imports = [_]spritz_build.KernelImport{
        .{ .name = "reduce", .path = dep_common.path("src/reduce.zig") },
    };
    const kopts: spritz_build.CompileOptions = .{
        .imports = &reduce_imports,
        .optimize = .ReleaseFast,
        .variable_pointers = true,
    };
    const sum_zig = spritz_build.compileKernel(b, dep, "sum_zig", b.path("src/kernel_sum.zig"), kopts);

    const install_spv = b.addInstallFileWithDir(sum_zig.spv, .prefix, "sum_zig.spv");

    const run = b.addRunArtifact(exe);
    run.addFileArg(sum_zig.spv);
    const run_step = b.step("run", "Run the chained two-pass reduce");
    run_step.dependOn(&run.step);

    const run_binary = b.addRunArtifact(exe);
    run_binary.addFileArg(sum_zig.spv);
    run_binary.addArg("--binary");

    const all = b.step("all", "Run both timeline and binary+fence variants");
    all.dependOn(&run.step);
    all.dependOn(&run_binary.step);

    b.default_step.dependOn(&exe.step);
    b.default_step.dependOn(&install_spv.step);
}
