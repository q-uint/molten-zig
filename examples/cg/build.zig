const std = @import("std");
const molten_build = @import("molten");

// GPU-resident CG: one exe loads all kernels and drives the iteration. Unlike
// the single-kernel examples, the run takes every spv path positionally, so we
// compile each kernel and pass them in a fixed order rather than using
// addRunAndBench (which wires one spv per run-<name> step).
//
// Each kernel is its own SPIR-V module (one OpEntryPoint named main), so each
// needs a distinct root that exports one of kernels.zig's structs. Those roots
// are 4-line stubs, generated here rather than committed.
// Kernel set, by snake_case tag. The exported struct in kernels.zig is the
// PascalCase of the tag (matvec -> Matvec, finish_dot -> FinishDot), so one
// tag drives both the spv name and the export. Keep in sync with
// kernels.KernelId, which the host indexes by the same order.
const tags = [_][]const u8{
    "matvec",
    "dot",
    "finish_dot",
    "compute_alpha",
    "compute_beta",
    "axpy_alpha",
    "update_p",
    "init_stop",
    "check_converged",
};

fn pascal(comptime tag: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var up = true;
        for (tag) |c| {
            if (c == '_') {
                up = true;
            } else if (up) {
                out = out ++ &[_]u8{std.ascii.toUpper(c)};
                up = false;
            } else {
                out = out ++ &[_]u8{c};
            }
        }
        return out;
    }
}

pub fn build(b: *std.Build) !void {
    const app = molten_build.standardExample(b, "cg", .{});

    const kernels_import = molten_build.KernelImport{
        .name = "kernels",
        .path = b.path("src/kernels.zig"),
    };

    const stubs = b.addWriteFiles();

    const run = b.addRunArtifact(app.exe);
    inline for (tags) |tag| {
        const type_name = comptime pascal(tag);
        const stub = stubs.add(tag ++ ".zig", std.fmt.comptimePrint(
            \\const kernels = @import("kernels");
            \\comptime {{
            \\    @export(&kernels.{s}.main, .{{ .name = "main" }});
            \\}}
            \\
        , .{type_name}));
        const art = molten_build.compileKernel(b, app.dep, tag, stub, .{
            .variable_pointers = true,
            .optimize = .ReleaseFast,
            .imports = &.{kernels_import},
        });
        const install = b.addInstallFileWithDir(art.spv, .prefix, tag ++ ".spv");
        b.default_step.dependOn(&install.step);
        run.addFileArg(art.spv);
    }

    const run_step = b.step("run", "Solve CG on GPU and parity-check the CPU reference");
    run_step.dependOn(&run.step);
    app.all.dependOn(&run.step);

    // Unit tests for the CPU reference solver (host target, no device).
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/cg.zig"),
        .target = app.target,
        .optimize = app.optimize,
    }) });
    const test_step = b.step("test", "Run the CPU reference CG unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
