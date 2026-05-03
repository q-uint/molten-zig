const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const env = b.graph.environ_map;
    const vulkan_sdk = env.get("VULKAN_SDK") orelse
        fatal("VULKAN_SDK not set (required by molten's build.zig) - enter the dev shell with `nix develop`", .{});
    const vk_loader_lib = env.get("VK_LOADER_LIB") orelse
        fatal("VK_LOADER_LIB not set (required by molten's build.zig) - enter the dev shell with `nix develop`", .{});
    const vk_loader_dir = std.fs.path.dirname(vk_loader_lib) orelse
        fatal("VK_LOADER_LIB={s} has no directory component", .{vk_loader_lib});
    const vulkan_include = b.pathJoin(&.{ vulkan_sdk, "include" });

    // Vulkan bindings via translate-c. Replaces the old @cImport in
    // src/internal/c.zig now that @cImport has moved to the build system
    // (Zig 0.16+). Produces a module that exposes the vulkan.h symbols
    // at the top level; src/internal/c.zig re-exports it as `vk`.
    const translate_vk = b.addTranslateC(.{
        .root_source_file = b.path("src/internal/vk.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_vk.addSystemIncludePath(.{ .cwd_relative = vulkan_include });

    // Public module: consumers add this as an import. Carries Vulkan
    // include/lib/link config so consumers don't repeat it.
    const molten = b.addModule("molten", .{
        .root_source_file = b.path("src/molten.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const vk_mod = translate_vk.createModule();
    molten.addImport("c", vk_mod);
    molten.linkSystemLibrary("vulkan", .{});
    molten.addIncludePath(.{ .cwd_relative = vulkan_include });
    molten.addLibraryPath(.{ .cwd_relative = vk_loader_dir });

    // Sanity check: compile the library on its own. Useful for catching
    // breakage even before any example builds.
    const lib_check = b.addLibrary(.{
        .name = "molten",
        .root_module = molten,
        .linkage = .static,
    });
    const check_step = b.step("check", "Type-check the molten library");
    check_step.dependOn(&lib_check.step);

    // Live-Vulkan tests. Each test that needs a device skips itself if
    // no usable Vulkan/MoltenVK runtime is available, so this is safe to
    // run even without the SDK on PATH (the link step still requires it).
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/diagnostics.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tests_mod.addImport("molten", molten);
    tests_mod.addImport("c", vk_mod);
    tests_mod.linkSystemLibrary("vulkan", .{});
    tests_mod.addIncludePath(.{ .cwd_relative = vulkan_include });
    tests_mod.addLibraryPath(.{ .cwd_relative = vk_loader_dir });
    const tests = b.addTest(.{ .root_module = tests_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    // GLSL parity: compile shader.comp -> shader.spv with glslangValidator,
    // validate it, install it. Consumers (the example) wire this into their
    // own dispatch step. Kept at the top level so it does not bit-rot.
    const glsl = b.addSystemCommand(&.{ "glslangValidator", "-V" });
    glsl.addFileArg(b.path("shader.comp"));
    glsl.addArg("-o");
    const raw_glsl_spv = glsl.addOutputFileArg("shader.spv");
    const glsl_spv = validateSpv(b, raw_glsl_spv, "shader.spv");
    const install_glsl_spv = b.addInstallFileWithDir(glsl_spv, .prefix, "shader.spv");

    const glsl_step = b.step("glsl-spv", "Compile shader.comp -> shader.spv with glslangValidator");
    glsl_step.dependOn(&install_glsl_spv.step);
}

pub const KernelArtifact = struct {
    /// LazyPath of the produced .spv. Use with addFileArg / @embedFile via b.addEmbedFile.
    /// When `validate` is enabled (the default), anything depending on this path
    /// transitively depends on spirv-val succeeding.
    spv: std.Build.LazyPath,
};

pub const KernelImport = struct {
    /// Name as seen by `@import` inside the kernel.
    name: []const u8,
    /// Source file backing the import.
    path: std.Build.LazyPath,
};

pub const TargetBits = enum { @"32", @"64" };

pub const CompileOptions = struct {
    /// Named modules importable from the kernel via `@import("<name>")`.
    /// The kernel compile is a raw `zig build-obj`, so it does not see the
    /// host build's modules; declare any cross-package imports here. Also
    /// covers cache invalidation: editing the imported file rebuilds.
    imports: []const KernelImport = &.{},
    /// Debug mode wraps integer ops in overflow checks; ReleaseFast skips them.
    optimize: std.builtin.OptimizeMode = .Debug,
    /// Set false to skip spirv-val. Useful when iterating on the SPIR-V backend.
    validate: bool = true,
    /// Enable the variable_pointers SPIR-V feature. Required for indexing
    /// runtime arrays (gpu.runtimeArray) in storage_buffer addrspace.
    variable_pointers: bool = false,
    /// Pointer/usize width. Defaults to 32 because GLSL/Vulkan compute is
    /// 32-bit by convention and MoltenVK lowers to a 32-bit Metal model.
    /// Switch to .@"64" for buffer device addresses or 64-bit atomics.
    target_bits: TargetBits = .@"32",
};

/// Build helper for consumers: compile a .zig kernel to a .spv file using
/// the patched compiler at vendor/zig/zig-out/bin/zig.
///
/// `dep` is the molten dependency obtained from `b.dependency("molten", .{})`.
pub fn compileKernel(
    b: *std.Build,
    dep: *std.Build.Dependency,
    kernel_name: []const u8,
    kernel_path: std.Build.LazyPath,
    opts: CompileOptions,
) KernelArtifact {
    const patched_zig = dep.path("vendor/zig/zig-out/bin/zig").getPath(b);
    std.Io.Dir.cwd().access(b.graph.io, patched_zig, .{}) catch
        fatal("patched zig missing at {s} - run scripts/build-zig.sh in the molten dep first", .{patched_zig});

    const opt_flag = switch (opts.optimize) {
        .Debug => "-ODebug",
        .ReleaseSafe => "-OReleaseSafe",
        .ReleaseFast => "-OReleaseFast",
        .ReleaseSmall => "-OReleaseSmall",
    };
    const target = switch (opts.target_bits) {
        .@"32" => "spirv32-vulkan",
        .@"64" => "spirv64-vulkan",
    };
    const compile = b.addSystemCommand(&.{
        patched_zig,
        "build-obj",
        "-target",
        target,
        "-fno-llvm",
        "-fno-lld",
        // Without -fstrip the SPIR-V module carries the full mangled
        // generic instantiation name on every OpName, which buries the
        // actual instructions in noise.
        "-fstrip",
        opt_flag,
    });
    if (opts.variable_pointers) compile.addArg("-mcpu=generic+variable_pointers");

    // Wire imports as named modules. `--dep` populates the next module's
    // import table, then `-Mroot=<kernel>` defines the root module that
    // consumes them. `-femit-bin` attaches to the root module, so it must
    // come after the root `-M`.
    for (opts.imports) |imp| compile.addArgs(&.{ "--dep", imp.name });
    compile.addPrefixedFileArg("-Mroot=", kernel_path);
    const out_name = b.fmt("{s}.spv", .{kernel_name});
    const raw_spv = compile.addPrefixedOutputFileArg("-femit-bin=", out_name);
    for (opts.imports) |imp| compile.addPrefixedFileArg(b.fmt("-M{s}=", .{imp.name}), imp.path);

    if (!opts.validate) return .{ .spv = raw_spv };
    return .{ .spv = validateSpv(b, raw_spv, out_name) };
}

/// Run spirv-val on `spv` and return a LazyPath that consumers must use
/// instead. Any step depending on the returned path transitively depends on
/// validation succeeding, so an invalid module fails the build before
/// anything downstream (install, run, disassemble) gets to see it.
pub fn validateSpv(
    b: *std.Build,
    spv: std.Build.LazyPath,
    basename: []const u8,
) std.Build.LazyPath {
    const validate = b.addSystemCommand(&.{"spirv-val"});
    validate.addFileArg(spv);

    const wf = b.addWriteFiles();
    wf.step.dependOn(&validate.step);
    return wf.addCopyFile(spv, basename);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
