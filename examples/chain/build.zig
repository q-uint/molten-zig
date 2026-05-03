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
    exe_mod.addImport("molten", dep.module("molten"));

    const exe = b.addExecutable(.{ .name = "chain", .root_module = exe_mod });
    b.installArtifact(exe);

    const reduce_imports = [_]molten_build.KernelImport{
        .{ .name = "reduce", .path = dep_common.path("src/reduce.zig") },
    };
    const kopts: molten_build.CompileOptions = .{
        .imports = &reduce_imports,
        .optimize = .ReleaseFast,
        .variable_pointers = true,
    };
    const sum_zig = molten_build.compileKernel(b, dep, "sum_zig", b.path("src/kernel_sum.zig"), kopts);

    const install_spv = b.addInstallFileWithDir(sum_zig.spv, .prefix, "sum_zig.spv");

    const run = b.addRunArtifact(exe);
    run.addFileArg(sum_zig.spv);
    const run_step = b.step("run", "Run the chained two-pass reduce");
    run_step.dependOn(&run.step);

    b.default_step.dependOn(&exe.step);
    b.default_step.dependOn(&install_spv.step);
}
