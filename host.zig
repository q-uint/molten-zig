// Usage: ./host <shader.spv>

const std = @import("std");
const vk = @cImport({
    @cDefine("VK_ENABLE_BETA_EXTENSIONS", "1");
    @cInclude("vulkan/vulkan.h");
});

const N: u32 = 1024;

fn check(result: vk.VkResult, comptime label: []const u8) !void {
    if (result != vk.VK_SUCCESS) {
        std.debug.print("{s} failed: VkResult={d}\n", .{ label, result });
        return error.VulkanCallFailed;
    }
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer arg_iter.deinit();
    _ = arg_iter.next() orelse return error.BadArgs;
    const spv_path = arg_iter.next() orelse {
        std.debug.print("usage: host <shader.spv>\n", .{});
        return error.BadArgs;
    };

    const spv_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, spv_path, alloc, .limited(64 * 1024 * 1024));
    defer alloc.free(spv_bytes);
    if (spv_bytes.len % 4 != 0) return error.SpvNotWordAligned;

    const app_info: vk.VkApplicationInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "molten-zig",
        .applicationVersion = 0,
        .pEngineName = "molten-zig",
        .engineVersion = 0,
        .apiVersion = vk.VK_API_VERSION_1_4,
    };

    // VK_KHR_portability_enumeration is required on macOS/MoltenVK.
    const inst_exts = [_][*c]const u8{
        vk.VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
    };

    const validation_layer = "VK_LAYER_KHRONOS_validation";
    const want_validation = try hasLayer(alloc, validation_layer);
    const layers = [_][*c]const u8{validation_layer};
    if (!want_validation) {
        std.debug.print("note: {s} not present, continuing without it\n", .{validation_layer});
    }

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
    defer vk.vkDestroyInstance(instance, null);

    var phys_count: u32 = 0;
    try check(vk.vkEnumeratePhysicalDevices(instance, &phys_count, null), "vkEnumeratePhysicalDevices(count)");
    if (phys_count == 0) return error.NoPhysicalDevices;
    const phys_devs = try alloc.alloc(vk.VkPhysicalDevice, phys_count);
    defer alloc.free(phys_devs);
    try check(vk.vkEnumeratePhysicalDevices(instance, &phys_count, phys_devs.ptr), "vkEnumeratePhysicalDevices(list)");
    const phys = phys_devs[0];

    var phys_props: vk.VkPhysicalDeviceProperties = undefined;
    vk.vkGetPhysicalDeviceProperties(phys, &phys_props);
    std.debug.print("device: {s}\n", .{std.mem.sliceTo(&phys_props.deviceName, 0)});

    var qf_count: u32 = 0;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(phys, &qf_count, null);
    const qf_props = try alloc.alloc(vk.VkQueueFamilyProperties, qf_count);
    defer alloc.free(qf_props);
    vk.vkGetPhysicalDeviceQueueFamilyProperties(phys, &qf_count, qf_props.ptr);

    var found_qf: ?u32 = null;
    for (qf_props, 0..) |qf, i| {
        if (qf.queueFlags & vk.VK_QUEUE_COMPUTE_BIT != 0) {
            found_qf = @intCast(i);
            break;
        }
    }
    const compute_qf = found_qf orelse return error.NoComputeQueue;

    const queue_prio: f32 = 1.0;
    const queue_info: vk.VkDeviceQueueCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = compute_qf,
        .queueCount = 1,
        .pQueuePriorities = &queue_prio,
    };
    // VK_KHR_portability_subset is required on MoltenVK devices.
    const dev_exts = [_][*c]const u8{vk.VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME};
    const dev_info: vk.VkDeviceCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledExtensionCount = dev_exts.len,
        .ppEnabledExtensionNames = &dev_exts,
    };
    var device: vk.VkDevice = undefined;
    try check(vk.vkCreateDevice(phys, &dev_info, null, &device), "vkCreateDevice");
    defer vk.vkDestroyDevice(device, null);

    var queue: vk.VkQueue = undefined;
    vk.vkGetDeviceQueue(device, compute_qf, 0, &queue);

    const buffer_size: vk.VkDeviceSize = N * @sizeOf(f32);

    const in_buf = try createBuffer(device, buffer_size, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    const out_buf = try createBuffer(device, buffer_size, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);

    var in_mem_req: vk.VkMemoryRequirements = undefined;
    vk.vkGetBufferMemoryRequirements(device, in_buf, &in_mem_req);
    var out_mem_req: vk.VkMemoryRequirements = undefined;
    vk.vkGetBufferMemoryRequirements(device, out_buf, &out_mem_req);

    const mem_type = try findMemoryType(
        phys,
        in_mem_req.memoryTypeBits & out_mem_req.memoryTypeBits,
        vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    );

    const in_mem = try allocateMemory(device, in_mem_req.size, mem_type);
    const out_mem = try allocateMemory(device, out_mem_req.size, mem_type);

    // Spec requires bound buffers be destroyed before their memory is freed.
    // LIFO defers: destroy buffers first, then free memory.
    defer vk.vkFreeMemory(device, out_mem, null);
    defer vk.vkFreeMemory(device, in_mem, null);
    defer vk.vkDestroyBuffer(device, out_buf, null);
    defer vk.vkDestroyBuffer(device, in_buf, null);

    try check(vk.vkBindBufferMemory(device, in_buf, in_mem, 0), "vkBindBufferMemory(in)");
    try check(vk.vkBindBufferMemory(device, out_buf, out_mem, 0), "vkBindBufferMemory(out)");

    {
        var ptr: ?*anyopaque = null;
        try check(vk.vkMapMemory(device, in_mem, 0, buffer_size, 0, &ptr), "vkMapMemory(in)");
        const data: [*]f32 = @ptrCast(@alignCast(ptr.?));
        for (0..N) |i| data[i] = @floatFromInt(i);
        vk.vkUnmapMemory(device, in_mem);
    }

    const bindings = [_]vk.VkDescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT,
            .pImmutableSamplers = null,
        },
        .{
            .binding = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT,
            .pImmutableSamplers = null,
        },
    };
    const ds_layout_info: vk.VkDescriptorSetLayoutCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = bindings.len,
        .pBindings = &bindings,
    };
    var ds_layout: vk.VkDescriptorSetLayout = undefined;
    try check(vk.vkCreateDescriptorSetLayout(device, &ds_layout_info, null, &ds_layout), "vkCreateDescriptorSetLayout");
    defer vk.vkDestroyDescriptorSetLayout(device, ds_layout, null);

    const pool_size: vk.VkDescriptorPoolSize = .{
        .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 2,
    };
    const pool_info: vk.VkDescriptorPoolCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 1,
        .poolSizeCount = 1,
        .pPoolSizes = &pool_size,
    };
    var pool: vk.VkDescriptorPool = undefined;
    try check(vk.vkCreateDescriptorPool(device, &pool_info, null, &pool), "vkCreateDescriptorPool");
    defer vk.vkDestroyDescriptorPool(device, pool, null);

    const ds_alloc_info: vk.VkDescriptorSetAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &ds_layout,
    };
    var ds: vk.VkDescriptorSet = undefined;
    try check(vk.vkAllocateDescriptorSets(device, &ds_alloc_info, &ds), "vkAllocateDescriptorSets");

    const buf_infos = [_]vk.VkDescriptorBufferInfo{
        .{ .buffer = in_buf, .offset = 0, .range = buffer_size },
        .{ .buffer = out_buf, .offset = 0, .range = buffer_size },
    };
    const writes = [_]vk.VkWriteDescriptorSet{
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = ds,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &buf_infos[0],
        },
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = ds,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &buf_infos[1],
        },
    };
    vk.vkUpdateDescriptorSets(device, writes.len, &writes, 0, null);

    const shader_info: vk.VkShaderModuleCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = spv_bytes.len,
        .pCode = @ptrCast(@alignCast(spv_bytes.ptr)),
    };
    var shader: vk.VkShaderModule = undefined;
    try check(vk.vkCreateShaderModule(device, &shader_info, null, &shader), "vkCreateShaderModule");
    defer vk.vkDestroyShaderModule(device, shader, null);

    const pl_layout_info: vk.VkPipelineLayoutCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &ds_layout,
    };
    var pl_layout: vk.VkPipelineLayout = undefined;
    try check(vk.vkCreatePipelineLayout(device, &pl_layout_info, null, &pl_layout), "vkCreatePipelineLayout");
    defer vk.vkDestroyPipelineLayout(device, pl_layout, null);

    const stage_info: vk.VkPipelineShaderStageCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = vk.VK_SHADER_STAGE_COMPUTE_BIT,
        .module = shader,
        .pName = "main",
    };
    const pipeline_info: vk.VkComputePipelineCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = stage_info,
        .layout = pl_layout,
    };
    var pipeline: vk.VkPipeline = undefined;
    try check(vk.vkCreateComputePipelines(device, null, 1, &pipeline_info, null, &pipeline), "vkCreateComputePipelines");
    defer vk.vkDestroyPipeline(device, pipeline, null);

    const cmd_pool_info: vk.VkCommandPoolCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = compute_qf,
    };
    var cmd_pool: vk.VkCommandPool = undefined;
    try check(vk.vkCreateCommandPool(device, &cmd_pool_info, null, &cmd_pool), "vkCreateCommandPool");
    defer vk.vkDestroyCommandPool(device, cmd_pool, null);

    const cmd_alloc_info: vk.VkCommandBufferAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = cmd_pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    var cmd: vk.VkCommandBuffer = undefined;
    try check(vk.vkAllocateCommandBuffers(device, &cmd_alloc_info, &cmd), "vkAllocateCommandBuffers");

    const begin_info: vk.VkCommandBufferBeginInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    try check(vk.vkBeginCommandBuffer(cmd, &begin_info), "vkBeginCommandBuffer");
    vk.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    vk.vkCmdBindDescriptorSets(cmd, vk.VK_PIPELINE_BIND_POINT_COMPUTE, pl_layout, 0, 1, &ds, 0, null);
    vk.vkCmdDispatch(cmd, N, 1, 1);

    const compute_to_host: vk.VkMemoryBarrier = .{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = vk.VK_ACCESS_HOST_READ_BIT,
    };
    vk.vkCmdPipelineBarrier(
        cmd,
        vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        vk.VK_PIPELINE_STAGE_HOST_BIT,
        0,
        1,
        &compute_to_host,
        0,
        null,
        0,
        null,
    );
    try check(vk.vkEndCommandBuffer(cmd), "vkEndCommandBuffer");

    const submit_info: vk.VkSubmitInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
    };
    try check(vk.vkQueueSubmit(queue, 1, &submit_info, null), "vkQueueSubmit");
    try check(vk.vkQueueWaitIdle(queue), "vkQueueWaitIdle");

    {
        var ptr: ?*anyopaque = null;
        try check(vk.vkMapMemory(device, out_mem, 0, buffer_size, 0, &ptr), "vkMapMemory(out)");
        defer vk.vkUnmapMemory(device, out_mem);
        const data: [*]const f32 = @ptrCast(@alignCast(ptr.?));

        var ok: u32 = 0;
        var bad_first: ?usize = null;
        for (0..N) |i| {
            const expected: f32 = @as(f32, @floatFromInt(i)) * 2.0;
            if (data[i] == expected) {
                ok += 1;
            } else if (bad_first == null) {
                bad_first = i;
            }
        }
        std.debug.print("first 8 outputs: ", .{});
        for (0..8) |i| std.debug.print("{d} ", .{data[i]});
        std.debug.print("\n{d}/{d} elements correct\n", .{ ok, N });
        if (bad_first) |i| {
            std.debug.print("first mismatch at {d}: got {d}, expected {d}\n", .{ i, data[i], @as(f32, @floatFromInt(i)) * 2.0 });
            return error.WrongResult;
        }
    }
    std.debug.print("ok\n", .{});
}

fn createBuffer(device: vk.VkDevice, size: vk.VkDeviceSize, usage: vk.VkBufferUsageFlags) !vk.VkBuffer {
    const info: vk.VkBufferCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = usage,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
    };
    var buf: vk.VkBuffer = undefined;
    try check(vk.vkCreateBuffer(device, &info, null, &buf), "vkCreateBuffer");
    return buf;
}

fn allocateMemory(device: vk.VkDevice, size: vk.VkDeviceSize, type_index: u32) !vk.VkDeviceMemory {
    const info: vk.VkMemoryAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = size,
        .memoryTypeIndex = type_index,
    };
    var mem: vk.VkDeviceMemory = undefined;
    try check(vk.vkAllocateMemory(device, &info, null, &mem), "vkAllocateMemory");
    return mem;
}

fn hasLayer(alloc: std.mem.Allocator, name: []const u8) !bool {
    var count: u32 = 0;
    try check(vk.vkEnumerateInstanceLayerProperties(&count, null), "vkEnumerateInstanceLayerProperties(count)");
    if (count == 0) return false;
    const props = try alloc.alloc(vk.VkLayerProperties, count);
    defer alloc.free(props);
    try check(vk.vkEnumerateInstanceLayerProperties(&count, props.ptr), "vkEnumerateInstanceLayerProperties(list)");
    for (props) |p| {
        if (std.mem.eql(u8, std.mem.sliceTo(&p.layerName, 0), name)) return true;
    }
    return false;
}

fn findMemoryType(phys: vk.VkPhysicalDevice, type_filter: u32, props: vk.VkMemoryPropertyFlags) !u32 {
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
