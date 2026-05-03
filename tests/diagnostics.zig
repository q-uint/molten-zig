const std = @import("std");
const molten = @import("molten");
const vk = @import("c");

// Skips silently if there's no usable Vulkan/MoltenVK runtime, since
// these tests need a live device.
fn initContextOrSkip(diag: *molten.Diagnostics) !molten.Context {
    return molten.Context.init(std.testing.allocator, .{ .diagnostics = diag }) catch |err| switch (err) {
        error.NoPhysicalDevice,
        error.InitializationFailed,
        error.IncompatibleDriver,
        error.MissingRequiredFeature,
        error.NoComputeQueue,
        => return error.SkipZigTest,
        else => return err,
    };
}

test "diagnostics: bogus instance layer maps to LayerNotPresent" {
    var diag: molten.Diagnostics = .{};

    const app_info: vk.VkApplicationInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "molten-zig-test",
        .apiVersion = vk.VK_API_VERSION_1_4,
    };
    const bogus_layer = "VK_LAYER_does_not_exist_xyz";
    const layers = [_][*c]const u8{bogus_layer};
    const inst_info: vk.VkInstanceCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = layers.len,
        .ppEnabledLayerNames = &layers,
    };

    var instance: vk.VkInstance = undefined;
    const err = molten.check(&diag, vk.vkCreateInstance(&inst_info, null, &instance), "vkCreateInstance");

    try std.testing.expectError(error.LayerNotPresent, err);
    try std.testing.expectEqualStrings("vkCreateInstance", diag.last_label);
    try std.testing.expectEqual(vk.VK_ERROR_LAYER_NOT_PRESENT, diag.last_result);
}

test "diagnostics: BadShader does not pollute diagnostics" {
    var diag: molten.Diagnostics = .{};
    var ctx = try initContextOrSkip(&diag);
    defer ctx.deinit();

    diag.reset();

    // 4 bytes, 4-byte aligned, but not the SPIR-V magic. Hits the early
    // BadShader return before any vkCreate* call runs.
    const not_spv = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const result = ctx.loadPipeline(&not_spv, .{ .binding_count = 1 });

    try std.testing.expectError(error.BadShader, result);
    try std.testing.expectEqualStrings("", diag.last_label);
    try std.testing.expectEqual(vk.VK_SUCCESS, diag.last_result);
}
