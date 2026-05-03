const std = @import("std");
const vk = @import("c");

/// Optional sink for the last failing VkResult and its call-site label.
pub const Diagnostics = struct {
    last_label: []const u8 = "",
    last_result: vk.VkResult = vk.VK_SUCCESS,

    pub fn reset(self: *Diagnostics) void {
        self.last_label = "";
        self.last_result = vk.VK_SUCCESS;
    }

    pub fn format(
        self: Diagnostics,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s} failed: VkResult={d}", .{ self.last_label, self.last_result });
    }
};

pub fn check(
    diag: ?*Diagnostics,
    result: vk.VkResult,
    comptime label: []const u8,
) Error!void {
    if (result == vk.VK_SUCCESS) return;
    if (diag) |d| {
        d.last_label = label;
        d.last_result = result;
    }
    return mapResult(result);
}

/// Subset re-exported by molten.Error.
pub const Error = error{
    OutOfHostMemory,
    OutOfDeviceMemory,
    DeviceLost,
    InitializationFailed,
    LayerNotPresent,
    ExtensionNotPresent,
    FeatureNotPresent,
    IncompatibleDriver,
    UnknownVulkanError,
};

fn mapResult(result: vk.VkResult) Error {
    return switch (result) {
        vk.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfHostMemory,
        vk.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.OutOfDeviceMemory,
        vk.VK_ERROR_DEVICE_LOST => error.DeviceLost,
        vk.VK_ERROR_INITIALIZATION_FAILED => error.InitializationFailed,
        vk.VK_ERROR_LAYER_NOT_PRESENT => error.LayerNotPresent,
        vk.VK_ERROR_EXTENSION_NOT_PRESENT => error.ExtensionNotPresent,
        vk.VK_ERROR_FEATURE_NOT_PRESENT => error.FeatureNotPresent,
        vk.VK_ERROR_INCOMPATIBLE_DRIVER => error.IncompatibleDriver,
        else => error.UnknownVulkanError,
    };
}
