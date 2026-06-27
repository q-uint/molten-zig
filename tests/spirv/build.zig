const std = @import("std");
const molten_build = @import("molten");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("molten", .{ .target = target, .optimize = optimize });

    const smokes = [_][]const u8{
        "barriers",
        "bindings",
        "storage_array",
    };

    const test_step = b.step("test-spirv", "Compile and validate every spirv smoke kernel");

    for (smokes) |name| {
        const src = b.fmt("src/{s}.zig", .{name});
        const k = molten_build.compileKernel(b, dep, name, b.path(src), .{
            .optimize = .ReleaseFast,
            .variable_pointers = true,
        });
        const install = b.addInstallFileWithDir(k.spv, .prefix, b.fmt("{s}.spv", .{name}));
        test_step.dependOn(&install.step);
    }

    // Known-failing backend repros: compile without spirv-val so the .spv is
    // still produced for inspection. `repros-validate` runs spirv-val and is
    // EXPECTED to fail until the backend fix lands. Kept out of `test-spirv`.
    const repros = [_][]const u8{
        "runtime_array",
    };
    const repro_step = b.step("repros", "Compile known-failing backend repro kernels (no validation)");
    const repro_val_step = b.step("repros-validate", "Run spirv-val on repros (expected to FAIL until fixed)");
    for (repros) |name| {
        const src = b.fmt("src/{s}.zig", .{name});
        const k = molten_build.compileKernel(b, dep, name, b.path(src), .{
            .optimize = .ReleaseFast,
            .variable_pointers = true,
            .validate = false,
        });
        const install = b.addInstallFileWithDir(k.spv, .prefix, b.fmt("{s}.spv", .{name}));
        repro_step.dependOn(&install.step);

        const val = b.addSystemCommand(&.{"spirv-val"});
        val.addFileArg(k.spv);
        repro_val_step.dependOn(&val.step);
    }

    b.default_step.dependOn(test_step);
}
