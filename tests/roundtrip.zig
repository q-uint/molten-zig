const std = @import("std");
const spritz = @import("spritz");

const double_spv = @embedFile("double_spv");
const atomic_sum_spv = @embedFile("atomic_sum_spv");

const N: usize = 256;

fn initContextOrSkip() !spritz.Context {
    return spritz.Context.init(std.testing.allocator, .{}) catch |err| switch (err) {
        error.NoPhysicalDevice,
        error.InitializationFailed,
        error.IncompatibleDriver,
        error.MissingRequiredFeature,
        error.NoComputeQueue,
        => return error.SkipZigTest,
        else => return err,
    };
}

test "buffer write/read round-trips host-visible memory" {
    var ctx = try initContextOrSkip();
    defer ctx.deinit();

    var buf = try ctx.createBuffer(f32, N);
    defer buf.deinit();

    var data: [N]f32 = undefined;
    for (0..N) |i| data[i] = @floatFromInt(i);
    try buf.write(&data);

    var out: [N]f32 = undefined;
    try buf.readInto(&out);
    try std.testing.expectEqualSlices(f32, &data, &out);
}

test "dispatch doubles every element" {
    var ctx = try initContextOrSkip();
    defer ctx.deinit();

    var in = try ctx.createBuffer(f32, N);
    defer in.deinit();
    var out = try ctx.createBuffer(f32, N);
    defer out.deinit();

    var input: [N]f32 = undefined;
    for (0..N) |i| input[i] = @floatFromInt(i);
    try in.write(&input);

    var pipeline = try ctx.loadPipeline(double_spv, .{ .binding_count = 2 });
    defer pipeline.deinit();

    try pipeline.dispatch(&.{ in.bind(), out.bind() }, .{ .groups = .{ 1, 1, 1 } });

    var result: [N]f32 = undefined;
    try out.readInto(&result);
    for (0..N) |i| try std.testing.expectEqual(input[i] * 2.0, result[i]);
}

test "atomicAdd accumulates across all lanes" {
    var ctx = try initContextOrSkip();
    defer ctx.deinit();

    var counter = try ctx.createBuffer(u32, 1);
    defer counter.deinit();
    try counter.write(&.{0});

    var pipeline = try ctx.loadPipeline(atomic_sum_spv, .{ .binding_count = 1 });
    defer pipeline.deinit();

    // 256 lanes/workgroup, 4 workgroups -> 1024 atomic increments of one cell.
    try pipeline.dispatch(&.{counter.bind()}, .{ .groups = .{ 4, 1, 1 } });

    var result: [1]u32 = undefined;
    try counter.readInto(&result);
    try std.testing.expectEqual(@as(u32, 1024), result[0]);
}

test "device-local buffer init copies through staging" {
    var ctx = try initContextOrSkip();
    defer ctx.deinit();

    var input: [N]f32 = undefined;
    for (0..N) |i| input[i] = @floatFromInt(i);

    var in = try ctx.createBufferInit(f32, &input);
    defer in.deinit();
    var out = try ctx.createBuffer(f32, N);
    defer out.deinit();

    var pipeline = try ctx.loadPipeline(double_spv, .{ .binding_count = 2 });
    defer pipeline.deinit();

    try pipeline.dispatch(&.{ in.bind(), out.bind() }, .{ .groups = .{ 1, 1, 1 } });

    var result: [N]f32 = undefined;
    try out.readInto(&result);
    for (0..N) |i| try std.testing.expectEqual(input[i] * 2.0, result[i]);
}

test "ring exhausts after ring_size records without reset" {
    var ctx = try initContextOrSkip();
    defer ctx.deinit();

    var in = try ctx.createBuffer(f32, N);
    defer in.deinit();
    var out = try ctx.createBuffer(f32, N);
    defer out.deinit();

    var pipeline = try ctx.loadPipeline(double_spv, .{ .binding_count = 2, .descriptor_ring_size = 2 });
    defer pipeline.deinit();

    var cmd = try spritz.CommandBuffer.init(&ctx);
    defer cmd.deinit();
    try cmd.begin();
    const binds = [_]spritz.BindEntry{ in.bind(), out.bind() };
    try pipeline.record(&cmd, &binds, .{ .groups = .{ 1, 1, 1 } });
    try pipeline.record(&cmd, &binds, .{ .groups = .{ 1, 1, 1 } });
    try std.testing.expectError(
        error.RingExhausted,
        pipeline.record(&cmd, &binds, .{ .groups = .{ 1, 1, 1 } }),
    );
}

test "record rejects wrong binding count" {
    var ctx = try initContextOrSkip();
    defer ctx.deinit();

    var in = try ctx.createBuffer(f32, N);
    defer in.deinit();

    var pipeline = try ctx.loadPipeline(double_spv, .{ .binding_count = 2 });
    defer pipeline.deinit();

    var cmd = try spritz.CommandBuffer.init(&ctx);
    defer cmd.deinit();
    try cmd.begin();
    const binds = [_]spritz.BindEntry{in.bind()};
    try std.testing.expectError(
        error.InvalidArgument,
        pipeline.record(&cmd, &binds, .{ .groups = .{ 1, 1, 1 } }),
    );
}

test "timestamp query measures dispatch duration" {
    var ctx = try initContextOrSkip();
    defer ctx.deinit();

    if (!ctx.timestampsSupported()) return error.SkipZigTest;

    var in = try ctx.createBuffer(f32, N);
    defer in.deinit();
    var out = try ctx.createBuffer(f32, N);
    defer out.deinit();
    var input: [N]f32 = undefined;
    for (0..N) |i| input[i] = @floatFromInt(i);
    try in.write(&input);

    var pipeline = try ctx.loadPipeline(double_spv, .{ .binding_count = 2 });
    defer pipeline.deinit();

    var pool = try spritz.QueryPool.init(&ctx, 2);
    defer pool.deinit();

    var cmd = try spritz.CommandBuffer.init(&ctx);
    defer cmd.deinit();
    try cmd.begin();
    pool.reset(&cmd);
    pool.writeTimestamp(&cmd, spritz.PipelineStage.top_of_pipe, 0);
    try pipeline.record(&cmd, &.{ in.bind(), out.bind() }, .{ .groups = .{ 1, 1, 1 } });
    pool.writeTimestamp(&cmd, spritz.PipelineStage.compute_shader, 1);
    cmd.barrierComputeToHost();
    try cmd.end();

    var fence = try spritz.Fence.init(&ctx);
    defer fence.deinit();
    try ctx.submit(.{ .cmd = &cmd, .fence = &fence });
    try fence.wait(std.time.ns_per_s);
    pipeline.ringReset();

    const elapsed = try pool.elapsedNs(0, 1);
    try std.testing.expect(elapsed > 0);
    try std.testing.expect(elapsed < std.time.ns_per_s);
}

test "loadPipeline rejects oversized push constant" {
    var ctx = try initContextOrSkip();
    defer ctx.deinit();

    const too_big = spritz.options.max_push_constant_size + 4;
    try std.testing.expectError(
        error.PushConstantTooLarge,
        ctx.loadPipeline(double_spv, .{ .binding_count = 2, .push_constant_size = too_big }),
    );
}
