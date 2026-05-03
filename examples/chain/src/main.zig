// Usage: ./chain <kernel.spv>
//
// Two-pass GPU reduction chained on the device with a binary semaphore.
// Pass 1 reduces N inputs into `partials` partial sums. Pass 2 reduces
// the partials into a single value. The two submits are ordered by a
// semaphore (signaled by submit 1, waited at COMPUTE_SHADER stage by
// submit 2), so the host never round-trips between them. Submit 2
// signals a fence; the host waits on the fence and reads the result.
//
// Demonstrates: Pipeline.record(), Context.submit(), Semaphore for
// device-side ordering, Fence for host-side completion.

const std = @import("std");
const molten = @import("molten");

const WORKGROUP_SIZE: u32 = 64;
const N: u32 = 1 << 14;
const TILE1: u32 = 64; // pass 1 tile

const Push = extern struct { n: u32, tile: u32 };

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer arg_it.deinit();
    _ = arg_it.next() orelse return error.BadArgs;
    const spv_path = arg_it.next() orelse return error.BadArgs;

    const spv = try std.Io.Dir.cwd().readFileAlloc(init.io, spv_path, alloc, .limited(64 * 1024 * 1024));
    defer alloc.free(spv);

    var ctx = try molten.Context.init(alloc, .{});
    defer ctx.deinit();
    std.debug.print("device: {s}\n", .{ctx.deviceName()});

    // Layout: N inputs -> P1 -> partials (N/TILE1) -> P2 -> final (1).
    const partials_count = N / TILE1;
    const tile2 = partials_count;
    if (partials_count % WORKGROUP_SIZE != 0) return error.InvalidArgument;

    const input = try alloc.alloc(u32, N);
    defer alloc.free(input);
    var expected: u64 = 0;
    for (input, 0..) |*p, i| {
        p.* = @intCast(i & 0xff);
        expected += p.*;
    }

    var in_buf = try ctx.createBuffer(u32, N);
    defer in_buf.deinit();
    var partials_buf = try ctx.createBuffer(u32, partials_count);
    defer partials_buf.deinit();
    var final_buf = try ctx.createBuffer(u32, 1);
    defer final_buf.deinit();
    try in_buf.write(input);

    // One pipeline reused for both passes. Default ring size of 4 has
    // plenty of headroom for two in-flight records.
    var pipeline = try ctx.loadPipeline(spv, .{
        .binding_count = 2,
        .push_constant_size = @sizeOf(Push),
    });
    defer pipeline.deinit();

    // GPU-side ordering: submit 1 signals, submit 2 waits at compute.
    var sem = try molten.Semaphore.init(&ctx);
    defer sem.deinit();
    // Host-side completion: submit 2 signals this fence.
    var fence = try molten.Fence.init(&ctx);
    defer fence.deinit();

    var cmd1 = try molten.CommandBuffer.init(&ctx);
    defer cmd1.deinit();
    var cmd2 = try molten.CommandBuffer.init(&ctx);
    defer cmd2.deinit();

    // Pass 1: input -> partials.
    const push1 = Push{ .n = N, .tile = TILE1 };
    try cmd1.begin();
    try pipeline.record(&cmd1, &.{ in_buf.bind(), partials_buf.bind() }, .{
        .groups = .{ partials_count / WORKGROUP_SIZE, 1, 1 },
        .push = std.mem.asBytes(&push1),
    });
    // partials are about to be read by another compute dispatch.
    cmd1.barrierComputeToCompute();
    try cmd1.end();

    // Pass 2: partials -> final.
    const push2 = Push{ .n = partials_count, .tile = tile2 };
    try cmd2.begin();
    try pipeline.record(&cmd2, &.{ partials_buf.bind(), final_buf.bind() }, .{
        .groups = .{ 1, 1, 1 }, // tile2 == partials_count -> one workgroup of 1 invocation
        .push = std.mem.asBytes(&push2),
    });
    cmd2.barrierComputeToHost();
    try cmd2.end();

    // Submit 1 signals `sem` when pass 1 finishes on the device.
    try ctx.submit(.{
        .cmd = &cmd1,
        .signals = &.{&sem},
    });
    // Submit 2 waits on `sem` at the compute stage before pass 2 reads
    // partials, and signals `fence` when pass 2 finishes.
    try ctx.submit(.{
        .cmd = &cmd2,
        .waits = &.{.{ .semaphore = &sem, .stage = molten.PipelineStage.compute_shader }},
        .fence = &fence,
    });

    // Wait for pass 2 only. No vkQueueWaitIdle, no host-side polling
    // between passes.
    try fence.wait(std.math.maxInt(u64));
    pipeline.ringReset();

    // tile2 == partials_count, so n/tile = 1 partial. The kernel
    // early-returns for gid >= 1; only invocation 0 runs the fold and
    // writes final[0]. Other 63 invocations in the workgroup are wasted
    // but the dispatch shape is the simplest thing that works.
    const result = try final_buf.read(alloc);
    defer alloc.free(result);
    const got: u64 = result[0];
    if (got != expected) {
        std.debug.print("chain mismatch: got {d} want {d}\n", .{ got, expected });
        return error.WrongResult;
    }
    std.debug.print("ok: chain sum u32 N={d} -> {d}\n", .{ N, got });
}
