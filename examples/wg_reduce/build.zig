const std = @import("std");
const molten_build = @import("molten");

pub fn build(b: *std.Build) !void {
    const app = molten_build.standardExample(b, "wg_reduce", .{});

    const wg_reduce_imports = [_]molten_build.KernelImport{
        .{ .name = "wg_reduce", .path = b.path("src/wg_reduce.zig") },
    };
    const kopts: molten_build.CompileOptions = .{
        .imports = &wg_reduce_imports,
        .optimize = .ReleaseFast,
    };
    const sum_zig = molten_build.compileKernel(b, app.dep, "sum_zig", b.path("src/kernel_sum.zig"), kopts);
    const max_zig = molten_build.compileKernel(b, app.dep, "max_zig", b.path("src/kernel_max.zig"), kopts);

    const shader = b.path("src/shader.comp");
    const sum_glsl = molten_build.compileGlsl(b, app.dep, "sum_glsl", shader, &.{ "T=uint", "OP(a,b)=((a)+(b))", "IDENTITY=0u" });
    const max_glsl = molten_build.compileGlsl(b, app.dep, "max_glsl", shader, &.{ "T=int", "OP(a,b)=max(a,b)", "IDENTITY=(-2147483648)" });

    const dis_step = b.step("dis", "Disassemble each .spv (raw and spirv-opt -O) into disassembly/");
    inline for (.{ "sum_zig", "max_zig", "sum_glsl", "max_glsl" }, .{ sum_zig, max_zig, sum_glsl, max_glsl }) |n, k| {
        molten_build.addDisassembly(b, dis_step, k.spv, n ++ ".spv.dis", false);
        molten_build.addDisassembly(b, dis_step, k.spv, n ++ ".opt.spv.dis", true);
    }

    molten_build.addRunAndBench(app, .{ .name = "sum", .spv = sum_zig.spv, .extra_args = &.{"sum"} });
    molten_build.addRunAndBench(app, .{ .name = "max", .spv = max_zig.spv, .extra_args = &.{"max"} });
    molten_build.addRunAndBench(app, .{ .name = "sum-glsl", .spv = sum_glsl.spv, .extra_args = &.{"sum"} });
    molten_build.addRunAndBench(app, .{ .name = "max-glsl", .spv = max_glsl.spv, .extra_args = &.{"max"} });
}
