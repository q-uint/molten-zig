const std = @import("std");
const molten_build = @import("molten");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("molten", .{ .target = target, .optimize = optimize });

    const smokes = [_][]const u8{
        "barriers",
        "bindings",
    };

    const test_step = b.step("test-spirv", "Compile and validate every std.gpu smoke kernel");

    for (smokes) |name| {
        const src = b.fmt("src/{s}.zig", .{name});
        const k = molten_build.compileKernel(b, dep, name, b.path(src), .{
            .optimize = .ReleaseFast,
        });
        const install = b.addInstallFileWithDir(k.spv, .prefix, b.fmt("{s}.spv", .{name}));
        test_step.dependOn(&install.step);
    }

    b.default_step.dependOn(test_step);
}
