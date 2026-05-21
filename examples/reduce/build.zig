const std = @import("std");
const molten_build = @import("molten");

pub fn build(b: *std.Build) !void {
    const app = molten_build.standardExample(b, "reduce", .{});

    const reduce_imports = [_]molten_build.KernelImport{
        .{ .name = "reduce", .path = app.common.path("src/reduce.zig") },
    };
    // ReleaseFast: Debug-mode codegen wraps every signed/unsigned integer
    // op with overflow-check scaffolding, which makes the kernel 6x larger
    // and obscures the comptime story. The asymmetry shows up clearly
    // between sum (overflow-checked add) and max (no check) in Debug.
    const kopts: molten_build.CompileOptions = .{
        .imports = &reduce_imports,
        .optimize = .ReleaseFast,
        .variable_pointers = true,
    };
    const sum_zig = molten_build.compileKernel(b, app.dep, "sum_zig", b.path("src/kernel_sum.zig"), kopts);
    const max_zig = molten_build.compileKernel(b, app.dep, "max_zig", b.path("src/kernel_max.zig"), kopts);

    const dis_step = b.step("dis", "Disassemble each .spv (raw and spirv-opt -O) into disassembly/");
    molten_build.addDisassembly(b, dis_step, sum_zig.spv, "sum_zig.spv.dis", false);
    molten_build.addDisassembly(b, dis_step, max_zig.spv, "max_zig.spv.dis", false);
    molten_build.addDisassembly(b, dis_step, sum_zig.spv, "sum_zig.opt.spv.dis", true);
    molten_build.addDisassembly(b, dis_step, max_zig.spv, "max_zig.opt.spv.dis", true);

    molten_build.addRunAndBench(app, .{ .name = "sum", .spv = sum_zig.spv, .extra_args = &.{"sum"} });
    molten_build.addRunAndBench(app, .{ .name = "max", .spv = max_zig.spv, .extra_args = &.{"max"} });
}
