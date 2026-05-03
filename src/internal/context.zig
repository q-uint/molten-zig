const std = @import("std");
const vk = @import("c");
const buffer = @import("buffer.zig");
const pipeline = @import("pipeline.zig");
const cmd_mod = @import("command.zig");
const molten = @import("../molten.zig");
const diag_mod = @import("diagnostics.zig");

pub const Diagnostics = diag_mod.Diagnostics;
pub const check = diag_mod.check;

const MAX_SEMAPHORES: u32 = molten.options.max_semaphores_per_submit;

pub const SemaphoreWait = struct {
    semaphore: *cmd_mod.Semaphore,
    /// Pipeline stage at which the wait takes effect. Use a constant from
    /// `molten.PipelineStage` (e.g. `.compute_shader` for a dispatch that
    /// consumes results signaled by a previous dispatch).
    stage: cmd_mod.PipelineStageFlags,
};

pub const SubmitOptions = struct {
    cmd: *const cmd_mod.CommandBuffer,
    /// Semaphores to wait on before this submit's work begins (each at
    /// its own pipeline stage).
    waits: []const SemaphoreWait = &.{},
    /// Semaphores to signal once this submit's work completes.
    signals: []const *cmd_mod.Semaphore = &.{},
    /// Optional fence signaled when the submit completes. Pass one to
    /// let the host wait without vkQueueWaitIdle.
    fence: ?*cmd_mod.Fence = null,
};

pub const Options = struct {
    app_name: [:0]const u8 = "molten-zig",
    enable_validation_if_available: bool = true,
    /// Optional sink for the most recent failing Vulkan call. The pointer
    /// must outlive the Context. Library code never writes to stderr; if
    /// you want a record of which call failed, pass one here.
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

    pub fn init(allocator: std.mem.Allocator, options: Options) !Context {
        const diag = options.diagnostics;
        const app_info: vk.VkApplicationInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = options.app_name,
            .applicationVersion = 0,
            .pEngineName = "molten-zig",
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
        // MoltenVK exposes exactly one device on Apple Silicon.
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
            .enabledExtensionCount = dev_exts.len,
            .ppEnabledExtensionNames = &dev_exts,
            .pEnabledFeatures = &enabled_features,
        };
        var device: vk.VkDevice = undefined;
        try check(diag, vk.vkCreateDevice(phys, &dev_info, null, &device), "vkCreateDevice");
        errdefer vk.vkDestroyDevice(device, null);

        var queue: vk.VkQueue = undefined;
        vk.vkGetDeviceQueue(device, queue_family, 0, &queue);

        const cmd_pool_info: vk.VkCommandPoolCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
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

    pub fn createBuffer(
        self: *Context,
        comptime T: type,
        count: usize,
    ) !buffer.Buffer(T) {
        return buffer.Buffer(T).init(self, count);
    }

    pub fn loadPipeline(self: *Context, spv_bytes: []const u8, options: pipeline.PipelineOptions) !pipeline.Pipeline {
        return pipeline.Pipeline.init(self, spv_bytes, options);
    }

    pub fn submit(self: *Context, options: SubmitOptions) !void {
        if (options.waits.len > MAX_SEMAPHORES or options.signals.len > MAX_SEMAPHORES)
            return error.TooManySemaphores;

        var wait_handles: [MAX_SEMAPHORES]vk.VkSemaphore = undefined;
        var wait_stages: [MAX_SEMAPHORES]vk.VkPipelineStageFlags = undefined;
        for (options.waits, 0..) |w, i| {
            std.debug.assert(w.semaphore.ctx == self);
            wait_handles[i] = w.semaphore.handle;
            wait_stages[i] = w.stage;
        }
        var signal_handles: [MAX_SEMAPHORES]vk.VkSemaphore = undefined;
        for (options.signals, 0..) |s, i| {
            std.debug.assert(s.ctx == self);
            signal_handles[i] = s.handle;
        }

        std.debug.assert(options.cmd.ctx == self);
        const cmd_handle = options.cmd.handle;
        const submit_info: vk.VkSubmitInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = @intCast(options.waits.len),
            .pWaitSemaphores = if (options.waits.len > 0) &wait_handles else null,
            .pWaitDstStageMask = if (options.waits.len > 0) &wait_stages else null,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd_handle,
            .signalSemaphoreCount = @intCast(options.signals.len),
            .pSignalSemaphores = if (options.signals.len > 0) &signal_handles else null,
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
