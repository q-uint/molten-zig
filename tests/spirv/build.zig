const std = @import("std");
const molten_build = @import("molten");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("molten", .{ .target = target, .optimize = optimize });

    const Smoke = struct { name: []const u8, optimize: std.builtin.OptimizeMode = .ReleaseFast };
    const smokes = [_]Smoke{
        .{ .name = "barriers" },
        .{ .name = "bindings" },
        .{ .name = "storage_array" },
        .{ .name = "runtime_array" },
        .{ .name = "atomics" },
        .{ .name = "intcast_signedness", .optimize = .Debug },
    };

    const test_step = b.step("test-spirv", "Compile and validate every spirv smoke kernel");

    for (smokes) |smoke| {
        const name = smoke.name;
        const src = b.fmt("src/{s}.zig", .{name});
        const k = molten_build.compileKernel(b, dep, name, b.path(src), .{
            .optimize = smoke.optimize,
            .variable_pointers = true,
        });
        const install = b.addInstallFileWithDir(k.spv, .prefix, b.fmt("{s}.spv", .{name}));
        test_step.dependOn(&install.step);
    }

    b.default_step.dependOn(test_step);
}
