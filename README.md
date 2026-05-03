# molten

Compute kernels written in Zig, lowered to SPIR-V via the self-hosted backend, dispatched on Apple Silicon GPUs through Vulkan/MoltenVK.

Apple Silicon only. Compute only. Early-stage learning project.

## Example

```zig
const std = @import("std");
const molten = @import("molten");

const N: u32 = 1024;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var ctx = try molten.Context.init(alloc, .{});
    defer ctx.deinit();

    var in  = try ctx.createBuffer(f32, N); defer in.deinit();
    var out = try ctx.createBuffer(f32, N); defer out.deinit();

    var input: [N]f32 = undefined;
    for (0..N) |i| input[i] = @floatFromInt(i);
    try in.write(&input);

    var pipeline = try ctx.loadPipeline(@embedFile("kernel.spv"), .{ .binding_count = 2 });
    defer pipeline.deinit();

    try pipeline.dispatch(&.{ in.bind(), out.bind() }, .{ .groups = .{ N, 1, 1 } });

    const result = try out.read(alloc); defer alloc.free(result);
    std.debug.print("first: {d}\n", .{result[0..4]});
}
```

See [examples/vector_multiply](examples/vector_multiply/) for the runnable consumer this snippet was distilled from. Other examples:

- [examples/reduce](examples/reduce/) - single-workgroup sum reduction
- [examples/wg_reduce](examples/wg_reduce/) - tiled reduction across workgroups, push-constant tail handling
- [examples/matrix_transpose](examples/matrix_transpose/) - shared-memory tile transpose
- [examples/chain](examples/chain/) - multi-dispatch pipeline reusing buffers across passes

## Architecture

```
Zig kernel (.zig)
   |  patched zig build-obj -target spirv64-vulkan
   v
SPIR-V (.spv)
   |  vkCreateShaderModule
   v
MoltenVK
   |  translates SPIR-V -> MSL, Vulkan -> Metal
   v
Metal
   v
Apple GPU
```

## Setup

```sh
nix develop                     # toolchain shell (cmake/ninja/llvm + Vulkan)
scripts/build-zig.sh            # first-time stage3 build of the patched zig (~30 min)
scripts/rebuild-zig.sh          # subsequent rebuilds after compiler edits (~30 s)
```

After `scripts/build-zig.sh` completes, `zig` on the shell PATH is the patched stage3 compiler (re-enter the shell to pick it up). Host code uses translate-c (Zig 0.17+ replaced `@cImport` with `b.addTranslateC`), so the patched compiler builds everything - host and kernels.

Then run an example:

```sh
cd examples/vector_multiply
zig build all                   # validate both kernels, dispatch both through MoltenVK
```

`build all` runs the example twice: once with the GLSL-derived `.spv` (the parity baseline), once with the Zig-derived `.spv`. Both must produce element-wise `2x` output.

## Kernel target

Kernels default to `spirv32-vulkan`. GLSL/Vulkan compute is 32-bit by convention and MoltenVK targets a 32-bit Metal model; spirv64 just makes Sema coerce every index to `u64` and emit pointless widening. Switch via `CompileOptions.target_bits = .@"64"` for buffer device addresses or 64-bit atomics.

## API surface

- `Context` - device/queue setup, buffer + pipeline factories, submission entry points (`submit`, `submitToFrame`).
- `Buffer` - host-visible storage buffer with `write`/`read`/`bind`. Lifetime is the caller's responsibility; must outlive any in-flight dispatch that references it.
- `Pipeline` - compute pipeline with a built-in descriptor-set ring (size configurable via `PipelineOptions.descriptor_ring_size`). `dispatch` is the one-shot path; `record` writes into a caller-owned `CommandBuffer`. Push constants are supported via `PipelineOptions.push_constant_size` and `DispatchOptions.push`.
- `CommandBuffer` - explicit recording for batching multiple dispatches in one submission.
- `FramePool` - ring of command buffers + per-frame fence, for back-to-back frames without per-call allocation.
- `Semaphore` / `Timeline` / `Fence` - binary and timeline sync primitives, wired through `SubmitOptions`.
- `Diagnostics` - optional sink threaded through `Context.init` and friends; captures the failing Vulkan call and `VkResult` so typed errors stay terse.

Tunables (override by declaring `pub const molten_options: molten.Options = .{ ... }` in your root file): `max_bindings`, `max_push_constant_size`, `max_descriptor_ring_size`, `default_descriptor_ring_size`, `max_semaphores_per_submit`.

## Scope

In scope: compute pipelines built from a single SPIR-V module, storage buffers in descriptor set 0, push constants, explicit command-buffer recording, and CPU/GPU sync via fences and binary or timeline semaphores. Enough to dispatch one or many kernels per frame and chain their results.

Out of scope (for now): graphics pipelines, images and samplers, multiple descriptor sets, specialization constants, multi-queue submission, and presentation/swapchains. The library is a thin layer over Vulkan compute - it doesn't try to hide Vulkan, just to make the common compute paths typed and pleasant from Zig.

Maturity: early. The API still moves between commits, examples are the canonical usage reference, and the patched Zig SPIR-V backend is itself a work in progress.
