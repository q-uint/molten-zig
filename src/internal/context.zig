const std = @import("std");
const vk = @import("c");
const buffer = @import("buffer.zig");
const pipeline = @import("pipeline.zig");
const cmd_mod = @import("command.zig");
const spritz = @import("../spritz.zig");
const diag_mod = @import("diagnostics.zig");

pub const Diagnostics = diag_mod.Diagnostics;
pub const check = diag_mod.check;

const MAX_SEMAPHORES: u32 = spritz.options.max_semaphores_per_submit;

pub const SemaphoreWait = struct {
    semaphore: *cmd_mod.Semaphore,
    stage: cmd_mod.PipelineStageFlags,
};

pub const TimelineWait = struct {
    timeline: *cmd_mod.Timeline,
    value: u64,
    stage: cmd_mod.PipelineStageFlags,
};

pub const TimelineSignal = struct {
    timeline: *cmd_mod.Timeline,
    value: u64,
};

pub const SubmitOptions = struct {
    cmd: *const cmd_mod.CommandBuffer,
    waits: []const SemaphoreWait = &.{},
    signals: []const *cmd_mod.Semaphore = &.{},
    timeline_waits: []const TimelineWait = &.{},
    timeline_signals: []const TimelineSignal = &.{},
    fence: ?*cmd_mod.Fence = null,
};

pub const Options = struct {
    app_name: [:0]const u8 = "spritz-zig",
    enable_validation_if_available: bool = true,
    diagnostics: ?*Diagnostics = null,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    instance: vk.VkInstance,
    phys: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    queue_family: u32,
    cmd_pool: vk.VkCommandPool,
    diag: ?*Diagnostics,
    device_name_buf: [vk.VK_MAX_PHYSICAL_DEVICE_NAME_SIZE]u8,
    device_name_len: usize,
    timestamp_period_ns: f64,
    timestamp_valid_bits: u32,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Context {
        const diag = options.diagnostics;
        const app_info: vk.VkApplicationInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = options.app_name,
            .applicationVersion = 0,
            .pEngineName = "spritz-zig",
            .engineVersion = 0,
            .apiVersion = vk.VK_API_VERSION_1_4,
        };

        const inst_exts = [_][*c]const u8{
            vk.VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
        };

        const validation_layer = "VK_LAYER_KHRONOS_validation";
        const want_validation = options.enable_validation_if_available and
            try hasLayer(allocator, diag, validation_layer);
        const layers = [_][*c]const u8{validation_layer};

        const inst_info: vk.VkInstanceCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .flags = vk.VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
            .pApplicationInfo = &app_info,
            .enabledExtensionCount = inst_exts.len,
            .ppEnabledExtensionNames = &inst_exts,
            .enabledLayerCount = if (want_validation) layers.len else 0,
            .ppEnabledLayerNames = if (want_validation) &layers else null,
        };

        var instance: vk.VkInstance = undefined;
        try check(diag, vk.vkCreateInstance(&inst_info, null, &instance), "vkCreateInstance");
        errdefer vk.vkDestroyInstance(instance, null);

        var phys_count: u32 = 0;
        try check(diag, vk.vkEnumeratePhysicalDevices(instance, &phys_count, null), "vkEnumeratePhysicalDevices(count)");
        if (phys_count == 0) return error.NoPhysicalDevice;
        const phys_devs = try allocator.alloc(vk.VkPhysicalDevice, phys_count);
        defer allocator.free(phys_devs);
        try check(diag, vk.vkEnumeratePhysicalDevices(instance, &phys_count, phys_devs.ptr), "vkEnumeratePhysicalDevices(list)");
        const phys = phys_devs[0];

        var qf_count: u32 = 0;
        vk.vkGetPhysicalDeviceQueueFamilyProperties(phys, &qf_count, null);
        const qf_props = try allocator.alloc(vk.VkQueueFamilyProperties, qf_count);
        defer allocator.free(qf_props);
        vk.vkGetPhysicalDeviceQueueFamilyProperties(phys, &qf_count, qf_props.ptr);

        var found_qf: ?u32 = null;
        for (qf_props, 0..) |qf, i| {
            if (qf.queueFlags & vk.VK_QUEUE_COMPUTE_BIT != 0) {
                found_qf = @intCast(i);
                break;
            }
        }
        const queue_family = found_qf orelse return error.NoComputeQueue;

        const queue_prio: f32 = 1.0;
        const queue_info: vk.VkDeviceQueueCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = queue_family,
            .queueCount = 1,
            .pQueuePriorities = &queue_prio,
        };
        // VK_KHR_portability_subset only exists on non-conformant portability
        // drivers (e.g. MoltenVK). The spec requires enabling it iff the device
        // advertises it; native drivers (incl. Linux lavapipe) don't, so
        // requesting it unconditionally fails vkCreateDevice with
        // VK_ERROR_EXTENSION_NOT_PRESENT.
        const want_portability = try hasDeviceExtension(allocator, diag, phys, vk.VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME);
        const dev_exts = [_][*c]const u8{vk.VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME};

        // SPIR-V backend needs Int8/16/64; runtimeArray needs variablePointers.
        var v11_features: vk.VkPhysicalDeviceVulkan11Features = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
        };
        var v12_features: vk.VkPhysicalDeviceVulkan12Features = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
            .pNext = &v11_features,
        };
        var features2: vk.VkPhysicalDeviceFeatures2 = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            .pNext = &v12_features,
        };
        vk.vkGetPhysicalDeviceFeatures2(phys, &features2);
        if (features2.features.shaderInt64 == 0 or
            features2.features.shaderInt16 == 0 or
            v12_features.shaderInt8 == 0 or
            v12_features.timelineSemaphore == 0 or
            v11_features.variablePointers == 0 or
            v11_features.variablePointersStorageBuffer == 0)
        {
            return error.MissingRequiredFeature;
        }

        const enabled_v11: vk.VkPhysicalDeviceVulkan11Features = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
            .variablePointers = vk.VK_TRUE,
            .variablePointersStorageBuffer = vk.VK_TRUE,
        };
        const enabled_v12: vk.VkPhysicalDeviceVulkan12Features = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
            .pNext = @constCast(&enabled_v11),
            .shaderInt8 = vk.VK_TRUE,
            .timelineSemaphore = vk.VK_TRUE,
        };
        const enabled_features: vk.VkPhysicalDeviceFeatures = .{
            .shaderInt64 = vk.VK_TRUE,
            .shaderInt16 = vk.VK_TRUE,
        };

        const dev_info: vk.VkDeviceCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = &enabled_v12,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
            .enabledExtensionCount = if (want_portability) dev_exts.len else 0,
            .ppEnabledExtensionNames = if (want_portability) &dev_exts else null,
            .pEnabledFeatures = &enabled_features,
        };
        var device: vk.VkDevice = undefined;
        try check(diag, vk.vkCreateDevice(phys, &dev_info, null, &device), "vkCreateDevice");
        errdefer vk.vkDestroyDevice(device, null);

        var queue: vk.VkQueue = undefined;
        vk.vkGetDeviceQueue(device, queue_family, 0, &queue);

        const cmd_pool_info: vk.VkCommandPoolCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            // Required for CommandBuffer.reset() to be spec-legal.
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = queue_family,
        };
        var cmd_pool: vk.VkCommandPool = undefined;
        try check(diag, vk.vkCreateCommandPool(device, &cmd_pool_info, null, &cmd_pool), "vkCreateCommandPool");
        errdefer vk.vkDestroyCommandPool(device, cmd_pool, null);

        var phys_props: vk.VkPhysicalDeviceProperties = undefined;
        vk.vkGetPhysicalDeviceProperties(phys, &phys_props);
        const name_slice = std.mem.sliceTo(&phys_props.deviceName, 0);

        var ctx: Context = .{
            .allocator = allocator,
            .instance = instance,
            .phys = phys,
            .device = device,
            .queue = queue,
            .queue_family = queue_family,
            .cmd_pool = cmd_pool,
            .diag = diag,
            .device_name_buf = undefined,
            .device_name_len = name_slice.len,
            .timestamp_period_ns = phys_props.limits.timestampPeriod,
            .timestamp_valid_bits = qf_props[queue_family].timestampValidBits,
        };
        @memcpy(ctx.device_name_buf[0..name_slice.len], name_slice);
        return ctx;
    }

    pub fn deinit(self: *Context) void {
        vk.vkDestroyCommandPool(self.device, self.cmd_pool, null);
        vk.vkDestroyDevice(self.device, null);
        vk.vkDestroyInstance(self.instance, null);
        self.* = undefined;
    }

    pub fn deviceName(self: *const Context) []const u8 {
        return self.device_name_buf[0..self.device_name_len];
    }

    /// True when the compute queue can record timestamps with a usable period.
    /// MoltenVK reports both on Apple Silicon; guard examples/tests on it anyway.
    pub fn timestampsSupported(self: *const Context) bool {
        return self.timestamp_valid_bits > 0 and self.timestamp_period_ns > 0;
    }

    pub fn waitIdle(self: *Context) !void {
        try check(self.diag, vk.vkQueueWaitIdle(self.queue), "vkQueueWaitIdle");
    }

    pub fn createBuffer(
        self: *Context,
        comptime T: type,
        count: usize,
    ) !buffer.Buffer(T) {
        return buffer.Buffer(T).init(self, count, .host_visible);
    }

    pub fn createDeviceBuffer(
        self: *Context,
        comptime T: type,
        count: usize,
    ) !buffer.Buffer(T) {
        return buffer.Buffer(T).init(self, count, .device_local);
    }

    /// Device-local buffer pre-filled via a transient staging copy. Drains
    /// the queue with vkQueueWaitIdle, so unrelated in-flight submits also
    /// stall; for batched or overlapping uploads drive recordCopyFrom yourself.
    pub fn createBufferInit(
        self: *Context,
        comptime T: type,
        data: []const T,
    ) !buffer.Buffer(T) {
        var dst = try buffer.Buffer(T).init(self, data.len, .device_local);
        errdefer dst.deinit();

        var staging = try buffer.Buffer(T).init(self, data.len, .host_visible);
        defer staging.deinit();
        try staging.write(data);

        var cmd = try cmd_mod.CommandBuffer.init(self);
        defer cmd.deinit();
        try cmd.begin();
        try dst.recordCopyFrom(&cmd, &staging);
        try cmd.end();

        try self.submit(.{ .cmd = &cmd });
        try check(self.diag, vk.vkQueueWaitIdle(self.queue), "vkQueueWaitIdle");
        return dst;
    }

    pub fn loadPipeline(self: *Context, spv_bytes: []const u8, options: pipeline.PipelineOptions) !pipeline.Pipeline {
        return pipeline.Pipeline.init(self, spv_bytes, options);
    }

    pub fn submit(self: *Context, options: SubmitOptions) !void {
        const wait_total = options.waits.len + options.timeline_waits.len;
        const signal_total = options.signals.len + options.timeline_signals.len;
        if (wait_total > MAX_SEMAPHORES or signal_total > MAX_SEMAPHORES)
            return error.TooManySemaphores;

        // Binary entries first, then timeline. Vulkan ignores values for binary slots.
        var wait_handles: [MAX_SEMAPHORES]vk.VkSemaphore = undefined;
        var wait_stages: [MAX_SEMAPHORES]vk.VkPipelineStageFlags = undefined;
        var wait_values: [MAX_SEMAPHORES]u64 = undefined;
        for (options.waits, 0..) |w, i| {
            std.debug.assert(w.semaphore.ctx == self);
            wait_handles[i] = w.semaphore.handle;
            wait_stages[i] = w.stage;
            wait_values[i] = 0;
        }
        for (options.timeline_waits, 0..) |w, j| {
            std.debug.assert(w.timeline.ctx == self);
            const i = options.waits.len + j;
            wait_handles[i] = w.timeline.handle;
            wait_stages[i] = w.stage;
            wait_values[i] = w.value;
        }

        var signal_handles: [MAX_SEMAPHORES]vk.VkSemaphore = undefined;
        var signal_values: [MAX_SEMAPHORES]u64 = undefined;
        for (options.signals, 0..) |s, i| {
            std.debug.assert(s.ctx == self);
            signal_handles[i] = s.handle;
            signal_values[i] = 0;
        }
        for (options.timeline_signals, 0..) |s, j| {
            std.debug.assert(s.timeline.ctx == self);
            const i = options.signals.len + j;
            signal_handles[i] = s.timeline.handle;
            signal_values[i] = s.value;
        }

        const has_timeline = options.timeline_waits.len > 0 or options.timeline_signals.len > 0;
        const timeline_info: vk.VkTimelineSemaphoreSubmitInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
            .waitSemaphoreValueCount = @intCast(wait_total),
            .pWaitSemaphoreValues = if (wait_total > 0) &wait_values else null,
            .signalSemaphoreValueCount = @intCast(signal_total),
            .pSignalSemaphoreValues = if (signal_total > 0) &signal_values else null,
        };

        std.debug.assert(options.cmd.ctx == self);
        const cmd_handle = options.cmd.handle;
        const submit_info: vk.VkSubmitInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = if (has_timeline) &timeline_info else null,
            .waitSemaphoreCount = @intCast(wait_total),
            .pWaitSemaphores = if (wait_total > 0) &wait_handles else null,
            .pWaitDstStageMask = if (wait_total > 0) &wait_stages else null,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd_handle,
            .signalSemaphoreCount = @intCast(signal_total),
            .pSignalSemaphores = if (signal_total > 0) &signal_handles else null,
        };
        const fence: vk.VkFence = if (options.fence) |f| f.handle else null;
        try check(self.diag, vk.vkQueueSubmit(self.queue, 1, &submit_info, fence), "vkQueueSubmit");
    }
};

fn hasLayer(allocator: std.mem.Allocator, diag: ?*Diagnostics, name: []const u8) !bool {
    var count: u32 = 0;
    try check(diag, vk.vkEnumerateInstanceLayerProperties(&count, null), "vkEnumerateInstanceLayerProperties(count)");
    if (count == 0) return false;
    const props = try allocator.alloc(vk.VkLayerProperties, count);
    defer allocator.free(props);
    try check(diag, vk.vkEnumerateInstanceLayerProperties(&count, props.ptr), "vkEnumerateInstanceLayerProperties(list)");
    for (props) |p| {
        if (std.mem.eql(u8, std.mem.sliceTo(&p.layerName, 0), name)) return true;
    }
    return false;
}

fn hasDeviceExtension(allocator: std.mem.Allocator, diag: ?*Diagnostics, phys: vk.VkPhysicalDevice, name: []const u8) !bool {
    var count: u32 = 0;
    try check(diag, vk.vkEnumerateDeviceExtensionProperties(phys, null, &count, null), "vkEnumerateDeviceExtensionProperties(count)");
    if (count == 0) return false;
    const props = try allocator.alloc(vk.VkExtensionProperties, count);
    defer allocator.free(props);
    try check(diag, vk.vkEnumerateDeviceExtensionProperties(phys, null, &count, props.ptr), "vkEnumerateDeviceExtensionProperties(list)");
    for (props) |p| {
        if (std.mem.eql(u8, std.mem.sliceTo(&p.extensionName, 0), name)) return true;
    }
    return false;
}

pub fn findMemoryType(phys: vk.VkPhysicalDevice, type_filter: u32, props: vk.VkMemoryPropertyFlags) !u32 {
    var mem_props: vk.VkPhysicalDeviceMemoryProperties = undefined;
    vk.vkGetPhysicalDeviceMemoryProperties(phys, &mem_props);
    for (0..mem_props.memoryTypeCount) |i| {
        const bit = @as(u32, 1) << @intCast(i);
        if ((type_filter & bit) != 0 and (mem_props.memoryTypes[i].propertyFlags & props) == props) {
            return @intCast(i);
        }
    }
    return error.NoSuitableMemoryType;
}
