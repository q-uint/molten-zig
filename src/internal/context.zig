const std = @import("std");
const vk = @import("c");
const buffer = @import("buffer.zig");
const pipeline = @import("pipeline.zig");

pub const Options = struct {
    app_name: [:0]const u8 = "molten-zig",
    enable_validation_if_available: bool = true,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    instance: vk.VkInstance,
    phys: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    queue_family: u32,
    cmd_pool: vk.VkCommandPool,
    device_name_buf: [vk.VK_MAX_PHYSICAL_DEVICE_NAME_SIZE]u8,
    device_name_len: usize,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Context {
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
            try hasLayer(allocator, validation_layer);
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
        try check(vk.vkCreateInstance(&inst_info, null, &instance), "vkCreateInstance");
        errdefer vk.vkDestroyInstance(instance, null);

        var phys_count: u32 = 0;
        try check(vk.vkEnumeratePhysicalDevices(instance, &phys_count, null), "vkEnumeratePhysicalDevices(count)");
        if (phys_count == 0) return error.VulkanError;
        const phys_devs = try allocator.alloc(vk.VkPhysicalDevice, phys_count);
        defer allocator.free(phys_devs);
        try check(vk.vkEnumeratePhysicalDevices(instance, &phys_count, phys_devs.ptr), "vkEnumeratePhysicalDevices(list)");
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
        const queue_family = found_qf orelse return error.VulkanError;

        const queue_prio: f32 = 1.0;
        const queue_info: vk.VkDeviceQueueCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = queue_family,
            .queueCount = 1,
            .pQueuePriorities = &queue_prio,
        };
        const dev_exts = [_][*c]const u8{vk.VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME};

        // The patched Zig SPIR-V backend declares Int8/Int16/Int64 capabilities
        // unconditionally. Enable the matching device features so MoltenVK
        // accepts the shader module without validation errors. Fail loudly if a
        // device claims not to support them - on Apple Silicon they are always
        // available via Metal.
        var v12_features: vk.VkPhysicalDeviceVulkan12Features = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
        };
        var features2: vk.VkPhysicalDeviceFeatures2 = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            .pNext = &v12_features,
        };
        vk.vkGetPhysicalDeviceFeatures2(phys, &features2);
        if (features2.features.shaderInt64 == 0 or
            features2.features.shaderInt16 == 0 or
            v12_features.shaderInt8 == 0)
        {
            std.debug.print(
                "device missing required int features: int64={d} int16={d} int8={d}\n",
                .{ features2.features.shaderInt64, features2.features.shaderInt16, v12_features.shaderInt8 },
            );
            return error.VulkanError;
        }

        const enabled_v12: vk.VkPhysicalDeviceVulkan12Features = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
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
        try check(vk.vkCreateDevice(phys, &dev_info, null, &device), "vkCreateDevice");
        errdefer vk.vkDestroyDevice(device, null);

        var queue: vk.VkQueue = undefined;
        vk.vkGetDeviceQueue(device, queue_family, 0, &queue);

        const cmd_pool_info: vk.VkCommandPoolCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .queueFamilyIndex = queue_family,
        };
        var cmd_pool: vk.VkCommandPool = undefined;
        try check(vk.vkCreateCommandPool(device, &cmd_pool_info, null, &cmd_pool), "vkCreateCommandPool");
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

    pub fn loadPipeline(self: *Context, spv_bytes: []const u8, binding_count: u32) !pipeline.Pipeline {
        return pipeline.Pipeline.init(self, spv_bytes, binding_count);
    }
};

pub fn check(result: vk.VkResult, comptime label: []const u8) !void {
    if (result != vk.VK_SUCCESS) {
        std.debug.print("{s} failed: VkResult={d}\n", .{ label, result });
        return error.VulkanError;
    }
}

fn hasLayer(allocator: std.mem.Allocator, name: []const u8) !bool {
    var count: u32 = 0;
    try check(vk.vkEnumerateInstanceLayerProperties(&count, null), "vkEnumerateInstanceLayerProperties(count)");
    if (count == 0) return false;
    const props = try allocator.alloc(vk.VkLayerProperties, count);
    defer allocator.free(props);
    try check(vk.vkEnumerateInstanceLayerProperties(&count, props.ptr), "vkEnumerateInstanceLayerProperties(list)");
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
    return error.VulkanError;
}
