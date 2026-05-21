// Shared scaffolding for the example programs: arg parsing, SPV load,
// context setup, and (for the simple two-buffer cases) element-wise
// verification. Sits on top of bench.zig so an example can verify once
// and then hand the same context/pipeline to a steady-state benchmark
// without re-doing the setup.

const std = @import("std");
const molten = @import("molten");

pub const bench = @import("bench.zig");

/// Parse `argv = exe spv_path [extra...]`. Returns the spv path and any
/// remaining args, so callers can layer their own selectors on top.
pub const Args = struct {
    spv_path: []const u8,
    rest: [][]const u8,

    pub fn parse(init: std.process.Init, alloc: std.mem.Allocator) !Args {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
        defer it.deinit();
        _ = it.next() orelse return error.BadArgs;
        const spv_path = it.next() orelse return error.BadArgs;

        var rest: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (rest.items) |a| alloc.free(a);
            rest.deinit(alloc);
        }
        while (it.next()) |a| {
            const dup = try alloc.dupe(u8, a);
            errdefer alloc.free(dup);
            try rest.append(alloc, dup);
        }

        const spv_owned = try alloc.dupe(u8, spv_path);
        errdefer alloc.free(spv_owned);
        const rest_owned = try rest.toOwnedSlice(alloc);
        return .{ .spv_path = spv_owned, .rest = rest_owned };
    }

    pub fn deinit(self: Args, alloc: std.mem.Allocator) void {
        for (self.rest) |a| alloc.free(a);
        alloc.free(self.rest);
        alloc.free(self.spv_path);
    }
};

/// Owns the SPV bytes and the molten Context for the lifetime of an
/// example run. Created once, used for verification and benchmarking.
pub const Session = struct {
    init: std.process.Init,
    alloc: std.mem.Allocator,
    ctx: molten.Context,
    spv: []u8,
    spv_path: []const u8,

    pub fn open(init: std.process.Init, alloc: std.mem.Allocator, spv_path: []const u8) !Session {
        const spv = try std.Io.Dir.cwd().readFileAlloc(init.io, spv_path, alloc, .limited(64 * 1024 * 1024));
        errdefer alloc.free(spv);

        var ctx = try molten.Context.init(alloc, .{});
        errdefer ctx.deinit();
        std.debug.print("device: {s}\n", .{ctx.deviceName()});

        return .{
            .init = init,
            .alloc = alloc,
            .ctx = ctx,
            .spv = spv,
            .spv_path = spv_path,
        };
    }

    pub fn deinit(self: *Session) void {
        self.ctx.deinit();
        self.alloc.free(self.spv);
    }

    /// Two-buffer (in, out) dispatch + element-wise check. Prints
    /// `ok: <label>` on success, returns error.WrongResult on the first
    /// mismatch. The kernel must take exactly two storage buffers of
    /// length `input.len * @sizeOf(T)`.
    pub fn verifyTwoBuffer(
        self: *Session,
        comptime T: type,
        cfg: struct {
            input: []const T,
            expected: []const T,
            groups: [3]u32,
            label: []const u8,
        },
    ) !void {
        std.debug.assert(cfg.input.len == cfg.expected.len);

        var in = try self.ctx.createBuffer(T, cfg.input.len);
        defer in.deinit();
        var out = try self.ctx.createBuffer(T, cfg.expected.len);
        defer out.deinit();
        try in.write(cfg.input);

        var pipeline = try self.ctx.loadPipeline(self.spv, .{ .binding_count = 2 });
        defer pipeline.deinit();
        try pipeline.dispatch(&.{ in.bind(), out.bind() }, .{ .groups = cfg.groups });

        const result = try out.read(self.alloc);
        defer self.alloc.free(result);
        for (result, cfg.expected, 0..) |got, want, i| {
            if (got != want) {
                std.debug.print("mismatch at {d}: got {any} want {any}\n", .{ i, got, want });
                return error.WrongResult;
            }
        }
        std.debug.print("ok: {s}\n", .{cfg.label});
    }

    /// Run a steady-state benchmark over `pipeline` + `bindings`. Fills
    /// in ctx/io from the session so callers only supply the
    /// kernel-specific bits.
    pub fn runBench(self: *Session, opts: BenchOptions) !bench.Stats {
        return bench.run(.{
            .label = opts.label,
            .io = self.init.io,
            .ctx = &self.ctx,
            .pipeline = opts.pipeline,
            .bindings = opts.bindings,
            .groups = opts.groups,
            .push = opts.push,
            .inner = opts.inner,
            .warmup = opts.warmup,
            .samples = opts.samples,
            .work = opts.work,
            .timeout_ns = opts.timeout_ns,
        });
    }
};

pub const BenchOptions = struct {
    label: []const u8,
    pipeline: *molten.Pipeline,
    bindings: []const molten.BindEntry,
    groups: [3]u32,
    push: ?[]const u8 = null,
    inner: u32 = 4,
    warmup: u32 = 3,
    samples: u32 = 32,
    work: bench.Work = .none,
    timeout_ns: u64 = 5 * std.time.ns_per_s,
};

/// Build a bench label of the form "<example> <variant>" where variant
/// is inferred from the spv basename: "kernel.spv" -> "zig",
/// "shader.spv" -> "glsl". If neither matches, returns the basename
/// (without extension) so the line is still identifiable.
///
/// `extra` is appended after the variant if non-null, useful for
/// per-op suffixes like "sum"/"max". The returned slice is owned by
/// `buf`.
pub fn benchLabel(
    buf: []u8,
    example: []const u8,
    spv_path: []const u8,
    extra: ?[]const u8,
) []const u8 {
    const base = std.fs.path.basename(spv_path);
    const variant: []const u8 = if (std.mem.eql(u8, base, "kernel.spv"))
        "zig"
    else if (std.mem.eql(u8, base, "shader.spv"))
        "glsl"
    else if (std.mem.indexOf(u8, base, "glsl") != null)
        "glsl"
    else if (std.mem.indexOf(u8, base, "zig") != null)
        "zig"
    else
        std.fs.path.stem(base);

    return if (extra) |x|
        std.fmt.bufPrint(buf, "{s} {s} {s}", .{ example, x, variant }) catch unreachable
    else
        std.fmt.bufPrint(buf, "{s} {s}", .{ example, variant }) catch unreachable;
}

test benchLabel {
    var buf: [64]u8 = undefined;
    const expectEqualStrings = std.testing.expectEqualStrings;

    try expectEqualStrings("vector_multiply zig", benchLabel(&buf, "vector_multiply", "zig-out/kernel.spv", null));
    try expectEqualStrings("vector_multiply glsl", benchLabel(&buf, "vector_multiply", "zig-out/shader.spv", null));
    try expectEqualStrings("reduce sum zig", benchLabel(&buf, "reduce", "zig-out/sum_zig.spv", "sum"));
    try expectEqualStrings("wg_reduce max glsl", benchLabel(&buf, "wg_reduce", "zig-out/max_glsl.spv", "max"));
    // Fallback: basename-derived variant when nothing else matches.
    try expectEqualStrings("foo bar", benchLabel(&buf, "foo", "zig-out/bar.spv", null));
}
