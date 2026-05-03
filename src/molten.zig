const context = @import("internal/context.zig");
const buffer = @import("internal/buffer.zig");
const pipeline = @import("internal/pipeline.zig");
const command = @import("internal/command.zig");
const diagnostics = @import("internal/diagnostics.zig");

pub const Context = context.Context;
pub const SubmitOptions = context.SubmitOptions;
pub const SemaphoreWait = context.SemaphoreWait;
pub const TimelineWait = context.TimelineWait;
pub const TimelineSignal = context.TimelineSignal;
pub const Buffer = buffer.Buffer;
pub const Pipeline = pipeline.Pipeline;
pub const PipelineOptions = pipeline.PipelineOptions;
pub const DispatchOptions = pipeline.DispatchOptions;
pub const BindEntry = pipeline.BindEntry;
pub const CommandBuffer = command.CommandBuffer;
pub const Semaphore = command.Semaphore;
pub const Timeline = command.Timeline;
pub const Fence = command.Fence;
pub const PipelineStage = command.PipelineStage;
pub const PipelineStageFlags = command.PipelineStageFlags;
pub const Diagnostics = diagnostics.Diagnostics;
pub const check = diagnostics.check;

/// Override via `pub const molten_options: molten.Options` in your root file.
pub const Options = struct {
    max_bindings: u32 = 16,
    max_push_constant_size: u32 = 128,
    max_descriptor_ring_size: u32 = 16,
    default_descriptor_ring_size: u32 = 4,
    max_semaphores_per_submit: u32 = 8,
};

pub const options: Options = if (@hasDecl(@import("root"), "molten_options"))
    @import("root").molten_options
else
    .{};

pub const Error = error{
    // VkResult mappings; the long tail collapses to UnknownVulkanError.
    OutOfHostMemory,
    OutOfDeviceMemory,
    DeviceLost,
    InitializationFailed,
    LayerNotPresent,
    ExtensionNotPresent,
    FeatureNotPresent,
    IncompatibleDriver,
    UnknownVulkanError,

    NoPhysicalDevice,
    NoComputeQueue,
    MissingRequiredFeature,
    NoSuitableMemoryType,

    BadShader,
    InvalidArgument,
    OutOfMemory,
    Timeout,
    RingExhausted,

    // Comptime-cap overflows; bump the matching molten.Options field.
    TooManyBindings,
    PushConstantTooLarge,
    RingSizeTooLarge,
    TooManySemaphores,
};
