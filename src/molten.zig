// Public API for the molten compute library.

const context = @import("internal/context.zig");
const buffer = @import("internal/buffer.zig");
const pipeline = @import("internal/pipeline.zig");
const diagnostics = @import("internal/diagnostics.zig");

pub const Context = context.Context;
pub const Buffer = buffer.Buffer;
pub const Pipeline = pipeline.Pipeline;
pub const PipelineOptions = pipeline.PipelineOptions;
pub const DispatchOptions = pipeline.DispatchOptions;
pub const Diagnostics = diagnostics.Diagnostics;
pub const check = diagnostics.check;

pub const Error = error{
    // VkResult mappings. The long tail collapses to UnknownVulkanError;
    // attach a Diagnostics to recover the exact VkResult and call site.
    OutOfHostMemory,
    OutOfDeviceMemory,
    DeviceLost,
    InitializationFailed,
    LayerNotPresent,
    ExtensionNotPresent,
    FeatureNotPresent,
    IncompatibleDriver,
    UnknownVulkanError,

    // Non-VkResult library conditions.
    NoPhysicalDevice,
    NoComputeQueue,
    MissingRequiredFeature,
    NoSuitableMemoryType,

    BadShader,
    InvalidArgument,
    OutOfMemory,
};
