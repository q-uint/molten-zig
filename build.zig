const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const env = b.graph.environ_map;
    const vulkan_sdk = env.get("VULKAN_SDK") orelse
        fatal("VULKAN_SDK not set - enter the dev shell with `nix develop`", .{});
    const vk_loader_lib = env.get("VK_LOADER_LIB") orelse
        fatal("VK_LOADER_LIB not set - enter the dev shell with `nix develop`", .{});
    const vk_loader_dir = std.fs.path.dirname(vk_loader_lib) orelse
        fatal("VK_LOADER_LIB={s} has no directory component", .{vk_loader_lib});
    const vulkan_include = b.pathJoin(&.{ vulkan_sdk, "include" });

    const host_mod = b.createModule(.{
        .root_source_file = b.path("host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_mod.linkSystemLibrary("vulkan", .{});
    host_mod.addIncludePath(.{ .cwd_relative = vulkan_include });
    host_mod.addLibraryPath(.{ .cwd_relative = vk_loader_dir });
    const host = b.addExecutable(.{ .name = "host", .root_module = host_mod });
    b.installArtifact(host);

    const glsl = b.addSystemCommand(&.{ "glslangValidator", "-V" });
    glsl.addFileArg(b.path("shader.comp"));
    glsl.addArg("-o");
    const glsl_spv = glsl.addOutputFileArg("shader.spv");
    const install_glsl_spv = b.addInstallFileWithDir(glsl_spv, .prefix, "shader.spv");

    const glsl_step = b.step("glsl-spv", "Compile shader.comp -> shader.spv with glslangValidator");
    glsl_step.dependOn(&install_glsl_spv.step);

    // Built by scripts/build-zig.sh (first time) and scripts/rebuild-zig.sh after edits.
    const patched_zig_path = b.pathFromRoot("vendor/zig/zig-out/bin/zig");
    std.Io.Dir.cwd().access(b.graph.io, patched_zig_path, .{}) catch
        fatal("patched zig missing at {s} - run scripts/build-zig.sh first", .{patched_zig_path});

    const probe = b.addSystemCommand(&.{
        patched_zig_path,
        "build-obj",
        "-target",
        "spirv64-vulkan",
        "-fno-llvm",
        "-fno-lld",
    });
    probe.addFileArg(b.path("probe.zig"));
    const probe_spv = probe.addPrefixedOutputFileArg("-femit-bin=", "probe.spv");
    const install_probe_spv = b.addInstallFileWithDir(probe_spv, .prefix, "probe.spv");

    const probe_step = b.step("probe-spv", "Compile probe.zig -> probe.spv with the patched Zig compiler");
    probe_step.dependOn(&install_probe_spv.step);

    const val_glsl = b.addSystemCommand(&.{"spirv-val"});
    val_glsl.addFileArg(glsl_spv);
    const val_zig = b.addSystemCommand(&.{"spirv-val"});
    val_zig.addFileArg(probe_spv);

    const validate_step = b.step("validate", "Run spirv-val on shader.spv and probe.spv");
    validate_step.dependOn(&val_glsl.step);
    validate_step.dependOn(&val_zig.step);

    const run_glsl = b.addRunArtifact(host);
    run_glsl.addFileArg(glsl_spv);
    const run_glsl_step = b.step("run-glsl", "Dispatch the GLSL-derived shader through MoltenVK");
    run_glsl_step.dependOn(&run_glsl.step);

    const run_zig = b.addRunArtifact(host);
    run_zig.addFileArg(probe_spv);
    const run_zig_step = b.step("run-zig", "Dispatch the Zig-derived shader through MoltenVK");
    run_zig_step.dependOn(&run_zig.step);

    const all = b.step("all", "Compile both shaders, validate them, dispatch both through MoltenVK");
    all.dependOn(validate_step);
    all.dependOn(&run_glsl.step);
    all.dependOn(&run_zig.step);

    b.default_step.dependOn(&host.step);
    b.default_step.dependOn(&install_glsl_spv.step);
    b.default_step.dependOn(&install_probe_spv.step);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
