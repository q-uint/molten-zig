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

    const exe = b.addExecutable(.{ .name = "reduce", .root_module = exe_mod });
    b.installArtifact(exe);

    const reduce_inputs = [_]std.Build.LazyPath{b.path("src/reduce.zig")};
    // ReleaseFast: Debug-mode codegen wraps every signed/unsigned integer
    // op with overflow-check scaffolding, which makes the kernel 6x larger
    // and obscures the comptime story. The asymmetry shows up clearly
    // between sum (overflow-checked add) and max (no check) in Debug.
    const kopts: molten_build.CompileOptions = .{
        .extra_inputs = &reduce_inputs,
        .optimize = .ReleaseFast,
        .variable_pointers = true,
    };
    const sum_zig = molten_build.compileKernel(b, dep, "sum_zig", b.path("src/kernel_sum.zig"), kopts);
    const max_zig = molten_build.compileKernel(b, dep, "max_zig", b.path("src/kernel_max.zig"), kopts);

    const installs = [_]*std.Build.Step{
        &b.addInstallFileWithDir(sum_zig.spv, .prefix, "sum_zig.spv").step,
        &b.addInstallFileWithDir(max_zig.spv, .prefix, "max_zig.spv").step,
    };

    const dis_step = b.step("dis", "Disassemble each .spv (raw and spirv-opt -O) into disassembly/");
    addDisassembly(b, dis_step, sum_zig.spv, "sum_zig.spv.dis", false);
    addDisassembly(b, dis_step, max_zig.spv, "max_zig.spv.dis", false);
    addDisassembly(b, dis_step, sum_zig.spv, "sum_zig.opt.spv.dis", true);
    addDisassembly(b, dis_step, max_zig.spv, "max_zig.opt.spv.dis", true);

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

    const all = b.step("all", "Dispatch every kernel");
    all.dependOn(&run_sum.step);
    all.dependOn(&run_max.step);

    b.default_step.dependOn(&exe.step);
    for (installs) |s| b.default_step.dependOn(s);
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
