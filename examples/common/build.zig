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
}
