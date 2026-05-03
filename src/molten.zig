// Public API for the molten compute library.

const context = @import("internal/context.zig");
const buffer = @import("internal/buffer.zig");
const pipeline = @import("internal/pipeline.zig");
const command = @import("internal/command.zig");
const diagnostics = @import("internal/diagnostics.zig");

pub const Context = context.Context;
pub const SubmitOptions = context.SubmitOptions;
pub const SemaphoreWait = context.SemaphoreWait;
pub const Buffer = buffer.Buffer;
pub const Pipeline = pipeline.Pipeline;
pub const PipelineOptions = pipeline.PipelineOptions;
pub const DispatchOptions = pipeline.DispatchOptions;
pub const BindEntry = pipeline.BindEntry;
pub const CommandBuffer = command.CommandBuffer;
pub const Semaphore = command.Semaphore;
pub const Fence = command.Fence;
pub const PipelineStage = command.PipelineStage;
pub const PipelineStageFlags = command.PipelineStageFlags;
pub const Diagnostics = diagnostics.Diagnostics;
pub const check = diagnostics.check;

/// Comptime knobs. Override by declaring `pub const molten_options: molten.Options`
/// in your root file - same pattern as std.options. Anything not set falls back
/// to the defaults below.
pub const Options = struct {
    /// Upper bound on storage-buffer bindings per pipeline. Sizes the
    /// stack scratch arrays in record(). Bump if a shader needs more.
    max_bindings: u32 = 16,

    /// Upper bound on push-constant size per pipeline, in bytes.
    max_push_constant_size: u32 = 128,

    /// Hard cap on a Pipeline's descriptor-set ring. Sizes the stack-
    /// allocated descriptor-set array. Bumping past your real in-flight
    /// concurrency is wasted memory.
    max_descriptor_ring_size: u32 = 16,

    /// Default descriptor-set ring size on a Pipeline. Caps in-flight
    /// dispatches against the same pipeline; bump per-pipeline via
    /// PipelineOptions.descriptor_ring_size when one shader needs more.
    default_descriptor_ring_size: u32 = 4,

    /// Cap on wait/signal semaphores per Context.submit call. Sizes the
    /// stack scratch arrays in submit(); bump if a workload chains more.
    max_semaphores_per_submit: u32 = 8,
};

pub const options: Options = if (@hasDecl(@import("root"), "molten_options"))
    @import("root").molten_options
else
    .{};

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
    Timeout,
    RingExhausted,

    // Configured-cap overflows. Distinct from InvalidArgument so callers
    // can tell "you blew the comptime budget" from "your inputs don't
    // match the pipeline shape". Bump the relevant `molten.Options` field.
    TooManyBindings,
    PushConstantTooLarge,
    RingSizeTooLarge,
    TooManySemaphores,
};
