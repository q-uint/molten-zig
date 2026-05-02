const std = @import("std");
const molten_build = @import("molten");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("molten", .{ .target = target, .optimize = optimize });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("molten", dep.module("molten"));

    const exe = b.addExecutable(.{ .name = "wg_reduce", .root_module = exe_mod });
    b.installArtifact(exe);

    const wg_reduce_inputs = [_]std.Build.LazyPath{b.path("src/wg_reduce.zig")};
    const kopts: molten_build.CompileOptions = .{
        .extra_inputs = &wg_reduce_inputs,
        .optimize = .ReleaseFast,
    };
    const sum_zig = molten_build.compileKernel(b, dep, "sum_zig", b.path("src/kernel_sum.zig"), kopts);
    const max_zig = molten_build.compileKernel(b, dep, "max_zig", b.path("src/kernel_max.zig"), kopts);

    const sum_glsl = compileWgGlsl(b, "sum_glsl", "uint", "((a)+(b))", "0u");
    const max_glsl = compileWgGlsl(b, "max_glsl", "int", "max(a,b)", "(-2147483648)");

    const installs = [_]*std.Build.Step{
        &b.addInstallFileWithDir(sum_zig.spv, .prefix, "sum_zig.spv").step,
        &b.addInstallFileWithDir(max_zig.spv, .prefix, "max_zig.spv").step,
        &b.addInstallFileWithDir(sum_glsl.spv, .prefix, "sum_glsl.spv").step,
        &b.addInstallFileWithDir(max_glsl.spv, .prefix, "max_glsl.spv").step,
    };

    const validate_step = b.step("validate", "Run spirv-val on all four kernels");
    validate_step.dependOn(sum_zig.validate);
    validate_step.dependOn(max_zig.validate);
    validate_step.dependOn(sum_glsl.validate);
    validate_step.dependOn(max_glsl.validate);

    const dis_step = b.step("dis", "Disassemble each .spv (raw and spirv-opt -O) into disassembly/");
    addDisassembly(b, dis_step, sum_zig.spv, "sum_zig.spv.dis", false);
    addDisassembly(b, dis_step, max_zig.spv, "max_zig.spv.dis", false);
    addDisassembly(b, dis_step, sum_glsl.spv, "sum_glsl.spv.dis", false);
    addDisassembly(b, dis_step, max_glsl.spv, "max_glsl.spv.dis", false);
    addDisassembly(b, dis_step, sum_zig.spv, "sum_zig.opt.spv.dis", true);
    addDisassembly(b, dis_step, max_zig.spv, "max_zig.opt.spv.dis", true);
    addDisassembly(b, dis_step, sum_glsl.spv, "sum_glsl.opt.spv.dis", true);
    addDisassembly(b, dis_step, max_glsl.spv, "max_glsl.opt.spv.dis", true);

    const run_sum = b.addRunArtifact(exe);
    run_sum.addFileArg(sum_zig.spv);
    run_sum.addArg("sum");
    const run_sum_step = b.step("run-sum", "Dispatch the Zig sum kernel");
    run_sum_step.dependOn(&run_sum.step);

    const run_max = b.addRunArtifact(exe);
    run_max.addFileArg(max_zig.spv);
    run_max.addArg("max");
    const run_max_step = b.step("run-max", "Dispatch the Zig max kernel");
    run_max_step.dependOn(&run_max.step);

    const run_sum_glsl = b.addRunArtifact(exe);
    run_sum_glsl.addFileArg(sum_glsl.spv);
    run_sum_glsl.addArg("sum");
    const run_sum_glsl_step = b.step("run-sum-glsl", "Dispatch the GLSL sum kernel");
    run_sum_glsl_step.dependOn(&run_sum_glsl.step);

    const run_max_glsl = b.addRunArtifact(exe);
    run_max_glsl.addFileArg(max_glsl.spv);
    run_max_glsl.addArg("max");
    const run_max_glsl_step = b.step("run-max-glsl", "Dispatch the GLSL max kernel");
    run_max_glsl_step.dependOn(&run_max_glsl.step);

    const all = b.step("all", "Validate and dispatch every kernel");
    all.dependOn(validate_step);
    all.dependOn(&run_sum.step);
    all.dependOn(&run_max.step);
    all.dependOn(&run_sum_glsl.step);
    all.dependOn(&run_max_glsl.step);

    b.default_step.dependOn(&exe.step);
    for (installs) |s| b.default_step.dependOn(s);
}

fn compileWgGlsl(
    b: *std.Build,
    name: []const u8,
    comptime T: []const u8,
    comptime op_macro: []const u8,
    comptime identity: []const u8,
) molten_build.KernelArtifact {
    const glsl = b.addSystemCommand(&.{ "glslangValidator", "-V" });
    glsl.addArg("-DT=" ++ T);
    glsl.addArg("-DOP(a,b)=" ++ op_macro);
    glsl.addArg("-DIDENTITY=" ++ identity);
    glsl.addFileArg(b.path("src/shader.comp"));
    glsl.addArg("-o");
    const out_name = b.fmt("{s}.spv", .{name});
    const spv = glsl.addOutputFileArg(out_name);

    const validate = b.addSystemCommand(&.{"spirv-val"});
    validate.addFileArg(spv);

    return .{ .spv = spv, .validate = &validate.step };
}

fn addDisassembly(
    b: *std.Build,
    step: *std.Build.Step,
    spv: std.Build.LazyPath,
    out_name: []const u8,
    optimize: bool,
) void {
    const source = if (optimize) blk: {
        const opt = b.addSystemCommand(&.{ "spirv-opt", "--strip-debug", "-O" });
        opt.addFileArg(spv);
        opt.addArg("-o");
        break :blk opt.addOutputFileArg(b.fmt("{s}.spv", .{out_name}));
    } else spv;

    const dis = b.addSystemCommand(&.{ "spirv-dis", "--no-color" });
    dis.addFileArg(source);
    dis.addArg("-o");
    const out = dis.addOutputFileArg(out_name);
    const install = b.addInstallFileWithDir(out, .{ .custom = "../disassembly" }, out_name);
    step.dependOn(&install.step);
}
