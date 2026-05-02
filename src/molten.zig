// Public API for the molten compute library.

const context = @import("internal/context.zig");
const buffer = @import("internal/buffer.zig");
const pipeline = @import("internal/pipeline.zig");

pub const Context = context.Context;
pub const Buffer = buffer.Buffer;
pub const Pipeline = pipeline.Pipeline;
pub const DispatchOptions = pipeline.DispatchOptions;

pub const Error = error{
    VulkanError,
    OutOfMemory,
    BadShader,
    InvalidArgument,
};
