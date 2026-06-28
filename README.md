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

- [examples/wg_reduce](examples/wg_reduce/) - single-workgroup tree reduction (shared scratch + barriers)
- [examples/reduce](examples/reduce/) - tiled reduction across workgroups, push-constant `(n, tile)`
- [examples/matrix_transpose](examples/matrix_transpose/) - shared-memory tile transpose
- [examples/gemm](examples/gemm/) - f32 GEMM, parity-checked against Accelerate `cblas_sgemm`
- [examples/convolution](examples/convolution/) - 3x3 box-sum stencil
- [examples/chain](examples/chain/) - multi-dispatch pipeline reusing buffers across passes
- [examples/cg](examples/cg/) - GPU-resident conjugate gradient: scalars and the stopping test stay on-device, parity-checked against a CPU reference

## Writing a kernel

Kernels `@import("gpu")` for the SPIR-V builtins and helpers (the build wires this module in automatically). Workgroup size is the entry point's calling convention; buffers are `@extern` globals decorated with a descriptor set/binding.

```zig
const gpu = @import("gpu");

const N: u32 = 1024;
const Buf = extern struct { data: [N]f32 };

const in_buf = gpu.storageBuffer(Buf, 0, 0, "in_buf");
const out_buf = gpu.storageBuffer(Buf, 0, 1, "out_buf");

export fn main() callconv(.{ .spirv_kernel = .{ .x = 64, .y = 1, .z = 1 } }) void {
    const i = gpu.global_invocation_id[0];
    if (i >= N) return;
    out_buf.*.data[i] = in_buf.*.data[i] * 2.0;
}
```

`gpu` provides:

- Builtins: `global_invocation_id`, `local_invocation_id`, `workgroup_id`, `num_workgroups`.
- Buffers: `storageBuffer`, `uniformBuffer`, `pushConstant` (typed `@extern` with `descriptor = .{ set, binding }`).
- Barriers: `controlBarrier`, `memoryBarrier`, `workgroupBarrier`, plus `Scope`/`MemorySemantics`.
- Atomics: `atomicAdd`, `atomicMax`, `atomicMin`, `atomicExchange` over a `*addrspace(.storage_buffer)` integer (device scope, relaxed).

Runtime-sized buffers use the `@SpirvType` builtin, indexed through a pointer to the array field (needs `CompileOptions.variable_pointers`):

```zig
const Buf = extern struct { data: @SpirvType(.{ .runtime_array = f32 }) };
const buf = @extern(*addrspace(.storage_buffer) Buf, .{
    .name = "buf",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
});
// ...
(&buf.data)[i] = value;
```

Shared workgroup memory is a `var ... addrspace(.shared)` global; see [examples/wg_reduce](examples/wg_reduce/) and [examples/gemm](examples/gemm/).

## Architecture

```
Zig kernel (.zig)
   |  patched zig build-obj -target spirv32-vulkan
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
zig build bench                 # steady-state timing of both kernels
```

`build all` runs the example twice: once with the GLSL-derived `.spv` (the parity baseline), once with the Zig-derived `.spv`. Both must produce element-wise `2x` output. From the repo root, `zig build examples` runs `all` across every example.

## Running tests and examples

There are two scopes. The repo root drives the molten library; each `examples/<name>/` is an independent package that consumes molten as a path dependency, so you `cd` into one to drive it directly.

From the repo root:

```sh
zig build check        # type-check the library (fast, no device)
zig build test         # library tests; each device test self-skips when no GPU is present
zig build examples     # run `zig build all` in every example
zig build examples-bench
```

`zig build test` at the root covers the library only. It does not run the examples' checks; `zig build examples` does that, by invoking each example's `all` step (into which parity checks are wired). The two are separate gates.

Inside an example directory the available steps vary by example:

```sh
cd examples/<name>
zig build            # compile kernels + exe, install the .spv files
zig build all        # dispatch every kernel variant once (verify)
zig build run        # run the program end to end (cg, chain)
zig build run-<v>    # run one named variant, e.g. run-zig / run-sum (reduce, gemm, ...)
zig build bench      # steady-state timing
zig build test       # host unit tests, no device (cg, common)
zig build dis        # disassemble the spv (reduce, wg_reduce)
```

The `cg` example splits its checks by what they need: `zig build test` runs the CPU reference against the analytic solution (host only, proves the algorithm), and `zig build run` solves on the GPU and parity-checks against that reference across several sizes (needs a device, proves the implementation). Its `run` is wired into `all`, so `zig build examples` from the root exercises the parity sweep too.

## Kernel target

Kernels default to `spirv32-vulkan`. GLSL/Vulkan compute is 32-bit by convention and MoltenVK targets a 32-bit Metal model; spirv64 just makes Sema coerce every index to `u64` and emit pointless widening. Switch via `CompileOptions.target_bits = .@"64"` for buffer device addresses or 64-bit-wide atomics (32-bit atomics work on the default target).

## API surface

- `Context` - device/queue setup, buffer + pipeline factories, and `submit` (waits, signals, timeline values, optional fence).
- `Buffer` - host-visible storage buffer with `write`/`read`/`bind`. Lifetime is the caller's responsibility; must outlive any in-flight dispatch that references it.
- `Pipeline` - compute pipeline with a built-in descriptor-set ring (size configurable via `PipelineOptions.descriptor_ring_size`). `dispatch` is the one-shot path; `record` writes into a caller-owned `CommandBuffer`. Push constants are supported via `PipelineOptions.push_constant_size` and `DispatchOptions.push`.
- `CommandBuffer` - explicit recording for batching multiple dispatches in one submission.
- `FramePool` - ring of command buffers + per-frame fence, for back-to-back frames without per-call allocation.
- `Semaphore` / `Timeline` / `Fence` - binary and timeline sync primitives, wired through `SubmitOptions`.
- `Diagnostics` - optional sink threaded through `Context.init` and friends; captures the failing Vulkan call and `VkResult` so typed errors stay terse.

Tunables (override by declaring `pub const molten_options: molten.Options = .{ ... }` in your root file): `max_bindings`, `max_push_constant_size`, `max_descriptor_ring_size`, `default_descriptor_ring_size`, `max_semaphores_per_submit`.

## Scope

In scope: compute pipelines built from a single SPIR-V module, storage buffers (fixed-size or `@SpirvType` runtime arrays) in descriptor set 0, uniform buffers, push constants, shared workgroup memory, barriers, integer atomics, explicit command-buffer recording, and CPU/GPU sync via fences and binary or timeline semaphores. Enough to dispatch one or many kernels per frame and chain their results.

Out of scope (for now): graphics pipelines, images and samplers, multiple descriptor sets, specialization constants, multi-queue submission, and presentation/swapchains. The library is a thin layer over Vulkan compute - it doesn't try to hide Vulkan, just to make the common compute paths typed and pleasant from Zig.

Maturity: early. The API still moves between commits, examples are the canonical usage reference, and the patched Zig SPIR-V backend is itself a work in progress.
