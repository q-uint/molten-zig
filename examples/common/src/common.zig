// Shared scaffolding for the example programs. Handles arg parsing, SPV
// load, context setup, dispatch, and element-wise verification so each
// example's main.zig can focus on what its kernel actually computes.

const std = @import("std");
const molten = @import("molten");

pub fn Run(comptime T: type) type {
    return struct {
        input: []const T,
        expected: []const T,
        groups: [3]u32,
        binding_count: u32 = 2,
        label: []const u8,
    };
}

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
        defer rest.deinit(alloc);
        while (it.next()) |a| try rest.append(alloc, try alloc.dupe(u8, a));

        return .{
            .spv_path = try alloc.dupe(u8, spv_path),
            .rest = try rest.toOwnedSlice(alloc),
        };
    }

    pub fn deinit(self: Args, alloc: std.mem.Allocator) void {
        for (self.rest) |a| alloc.free(a);
        alloc.free(self.rest);
        alloc.free(self.spv_path);
    }
};

/// Load spv, set up context, dispatch, verify element-wise. Prints
/// `device: ...` and `ok: <label>` on success; returns error.WrongResult
/// on the first mismatch.
///
/// `input` and `expected` must both have length equal to the buffer size.
/// The kernel must take exactly two storage buffers: in at binding 0,
/// out at binding 1, both sized `input.len * @sizeOf(T)`.
pub fn run(
    comptime T: type,
    init: std.process.Init,
    alloc: std.mem.Allocator,
    spv_path: []const u8,
    cfg: Run(T),
) !void {
    std.debug.assert(cfg.input.len == cfg.expected.len);

    const spv = try std.Io.Dir.cwd().readFileAlloc(init.io, spv_path, alloc, .limited(64 * 1024 * 1024));
    defer alloc.free(spv);

    var ctx = try molten.Context.init(alloc, .{});
    defer ctx.deinit();
    std.debug.print("device: {s}\n", .{ctx.deviceName()});

    var in = try ctx.createBuffer(T, cfg.input.len);
    defer in.deinit();
    var out = try ctx.createBuffer(T, cfg.expected.len);
    defer out.deinit();

    try in.write(cfg.input);

    var pipeline = try ctx.loadPipeline(spv, cfg.binding_count);
    defer pipeline.deinit();
    try pipeline.dispatch(&.{ in.bind(), out.bind() }, .{ .groups = cfg.groups });

    const result = try out.read(alloc);
    defer alloc.free(result);
    for (result, cfg.expected, 0..) |got, want, i| {
        if (got != want) {
            std.debug.print("mismatch at {d}: got {any} want {any}\n", .{ i, got, want });
            return error.WrongResult;
        }
    }
    std.debug.print("ok: {s}\n", .{cfg.label});
}
