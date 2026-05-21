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

    // Meta-steps that run `zig build all` / `zig build bench` in every
    // example package. Each example is an independent package with its
    // own build.zig consuming molten as a path dependency, so we shell
    // out rather than wiring the child build graphs in - that would
    // re-enter this build.zig as a dependency and tangle target/optimize
    // propagation. Only registered when this build.zig is the top-level
    // invocation; when consumed as a dependency (the examples themselves
    // do this), it would recurse.
    if (b.dep_prefix.len == 0) try registerExamplesSteps(b);
}

fn registerExamplesSteps(b: *std.Build) !void {
    const examples_step = b.step("examples", "Run `zig build all` in every example");
    const bench_step = b.step("examples-bench", "Run `zig build bench` in every example that has one");
    const io = b.graph.io;
    var examples_dir = try b.build_root.handle.openDir(io, "examples", .{ .iterate = true });
    defer examples_dir.close(io);
    var it = examples_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        // common/ is a shared library package consumed by other examples;
        // it has no `all` step of its own.
        if (std.mem.eql(u8, entry.name, "common")) continue;
        // chain/ has no bench step (no --bench support in its main.zig).
        const has_bench = !std.mem.eql(u8, entry.name, "chain");

        const ex_path = b.pathJoin(&.{ "examples", entry.name });
        b.build_root.handle.access(io, b.pathJoin(&.{ ex_path, "build.zig" }), .{}) catch continue;

        const run_all = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "all" });
        run_all.setCwd(b.path(ex_path));
        run_all.setName(b.fmt("zig build all ({s})", .{entry.name}));
        examples_step.dependOn(&run_all.step);

        if (has_bench) {
            const run_bench = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "bench" });
            run_bench.setCwd(b.path(ex_path));
            run_bench.setName(b.fmt("zig build bench ({s})", .{entry.name}));
            bench_step.dependOn(&run_bench.step);
        }
    }
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

/// Shared scaffolding for an example app. Wires the `molten` + `common`
/// path deps, builds the exe module, installs the artifact, and exposes
/// the bits later steps need (the dep handle for compileKernel, the
/// `all`/`bench` step roots). Each example calls this then layers on its
/// own kernel compiles and run/bench variants.
pub const ExampleApp = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dep: *std.Build.Dependency,
    common: *std.Build.Dependency,
    exe: *std.Build.Step.Compile,
    /// Aggregator for `zig build all` - depended on by every run variant.
    all: *std.Build.Step,
    /// Aggregator for `zig build bench` - depended on by every bench variant.
    bench: *std.Build.Step,
};

pub const ExampleOptions = struct {
    /// Extra framework names to link (e.g. "Accelerate" for gemm). Picks
    /// up SDKROOT from the environment for the framework search path,
    /// matching how the Apple toolchain locates system frameworks.
    frameworks: []const []const u8 = &.{},
};

pub fn standardExample(b: *std.Build, name: []const u8, opts: ExampleOptions) ExampleApp {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("molten", .{ .target = target, .optimize = optimize });
    const common = b.dependency("common", .{ .target = target, .optimize = optimize });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("molten", dep.module("molten"));
    exe_mod.addImport("common", common.module("common"));

    if (opts.frameworks.len > 0) {
        if (b.graph.environ_map.get("SDKROOT")) |sdk| {
            exe_mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
        }
        for (opts.frameworks) |fw| exe_mod.linkFramework(fw, .{});
    }

    const exe = b.addExecutable(.{ .name = name, .root_module = exe_mod });
    b.installArtifact(exe);
    b.default_step.dependOn(&exe.step);

    const all = b.step("all", "Dispatch every kernel");
    const bench = b.step("bench", "Benchmark every kernel");

    return .{
        .b = b,
        .target = target,
        .optimize = optimize,
        .dep = dep,
        .common = common,
        .exe = exe,
        .all = all,
        .bench = bench,
    };
}

pub const Variant = struct {
    /// Short identifier used in step names (`run-<name>`). Conventionally
    /// "zig"/"glsl" for parity kernels, or "sum"/"max" when a single
    /// kernel takes an op selector.
    name: []const u8,
    spv: std.Build.LazyPath,
    /// Args passed to the exe before `--bench`. Use this for the op
    /// selector (`reduce` takes "sum"/"max") or the dispatch-shape kind
    /// (`matrix_transpose` takes "zig"/"glsl").
    extra_args: []const []const u8 = &.{},
    /// Install the spv next to the exe under <name>.spv. Defaults true;
    /// turn off if the example doesn't need the file on disk.
    install: bool = true,
    /// Install basename. Defaults to "<name>.spv".
    install_name: ?[]const u8 = null,
};

/// Wire `run-<name>` + bench variant + install for one kernel. Contributes
/// to the app's `all`/`bench` aggregators so a single `zig build all` or
/// `zig build bench` covers every registered variant.
pub fn addRunAndBench(app: ExampleApp, variant: Variant) void {
    const b = app.b;

    if (variant.install) {
        const install_name = variant.install_name orelse b.fmt("{s}.spv", .{variant.name});
        const install = b.addInstallFileWithDir(variant.spv, .prefix, install_name);
        b.default_step.dependOn(&install.step);
    }

    const run = b.addRunArtifact(app.exe);
    run.addFileArg(variant.spv);
    for (variant.extra_args) |a| run.addArg(a);
    const run_step = b.step(b.fmt("run-{s}", .{variant.name}), b.fmt("Dispatch the {s} kernel", .{variant.name}));
    run_step.dependOn(&run.step);
    app.all.dependOn(&run.step);

    const bench_run = b.addRunArtifact(app.exe);
    bench_run.addFileArg(variant.spv);
    for (variant.extra_args) |a| bench_run.addArg(a);
    bench_run.addArg("--bench");
    app.bench.dependOn(&bench_run.step);
}

/// Compile a GLSL compute shader with glslangValidator and validate the
/// result with spirv-val. `defines` are passed through as `-D` flags so
/// callers can parameterise a shared shader.comp (see wg_reduce).
pub fn compileGlsl(
    b: *std.Build,
    name: []const u8,
    source: std.Build.LazyPath,
    defines: []const []const u8,
) KernelArtifact {
    const glsl = b.addSystemCommand(&.{ "glslangValidator", "-V" });
    for (defines) |d| glsl.addArg(b.fmt("-D{s}", .{d}));
    glsl.addFileArg(source);
    glsl.addArg("-o");
    const out_name = b.fmt("{s}.spv", .{name});
    const raw_spv = glsl.addOutputFileArg(out_name);
    return .{ .spv = validateSpv(b, raw_spv, out_name) };
}

/// Disassemble `spv` (optionally via `spirv-opt -O` first) and install it
/// under disassembly/<out_name>. The two reduce examples both wanted
/// this; lives here so they share one implementation.
pub fn addDisassembly(
    b: *std.Build,
    step: *std.Build.Step,
    spv: std.Build.LazyPath,
    out_name: []const u8,
    optimize: bool,
) void {
    const source = if (optimize) blk: {
        const opt = b.addSystemCommand(&.{ "spirv-opt", "--strip-debug", "-O" });
        opt.addFileArg(spv);
        opt.addArg("-o");
        break :blk opt.addOutputFileArg(b.fmt("{s}.spv", .{out_name}));
    } else spv;

    const dis = b.addSystemCommand(&.{ "spirv-dis", "--no-color" });
    dis.addFileArg(source);
    dis.addArg("-o");
    const out = dis.addOutputFileArg(out_name);
    const install = b.addInstallFileWithDir(out, .{ .custom = "../disassembly" }, out_name);
    step.dependOn(&install.step);
}
