const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_molten = b.dependency("molten", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("common", .{
        .root_source_file = b.path("src/common.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("molten", dep_molten.module("molten"));

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Unit-test the common helpers");
    test_step.dependOn(&run_tests.step);
}
