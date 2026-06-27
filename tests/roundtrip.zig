const std = @import("std");
const molten = @import("molten");

const double_spv = @embedFile("double_spv");

const N: usize = 256;

fn initContextOrSkip() !molten.Context {
    return molten.Context.init(std.testing.allocator, .{}) catch |err| switch (err) {
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

    var cmd = try molten.CommandBuffer.init(&ctx);
    defer cmd.deinit();
    try cmd.begin();
    const binds = [_]molten.BindEntry{ in.bind(), out.bind() };
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

    var cmd = try molten.CommandBuffer.init(&ctx);
    defer cmd.deinit();
    try cmd.begin();
    const binds = [_]molten.BindEntry{in.bind()};
    try std.testing.expectError(
        error.InvalidArgument,
        pipeline.record(&cmd, &binds, .{ .groups = .{ 1, 1, 1 } }),
    );
}

test "loadPipeline rejects oversized push constant" {
    var ctx = try initContextOrSkip();
    defer ctx.deinit();

    const too_big = molten.options.max_push_constant_size + 4;
    try std.testing.expectError(
        error.PushConstantTooLarge,
        ctx.loadPipeline(double_spv, .{ .binding_count = 2, .push_constant_size = too_big }),
    );
}
