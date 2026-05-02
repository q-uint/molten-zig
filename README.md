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

    var pipeline = try ctx.loadPipeline(@embedFile("kernel.spv"), 2);
    defer pipeline.deinit();

    try pipeline.dispatch(&.{ in.bind(), out.bind() }, .{ .groups = .{ N, 1, 1 } });

    const result = try out.read(alloc); defer alloc.free(result);
    std.debug.print("first: {d}\n", .{result[0..4]});
}
```

See [examples/vector_multiply](examples/vector_multiply/) for the runnable consumer this snippet was distilled from.

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

Then run the example:

```sh
cd examples/vector_multiply
zig build all                   # validate both kernels, dispatch both through MoltenVK
```

`build all` runs the example twice: once with the GLSL-derived `.spv` (the parity baseline), once with the Zig-derived `.spv`. Both must produce element-wise `2x` output.

## Status

Works end-to-end for compute kernels using N storage buffers in set 0 (capped at `MAX_BINDINGS = 16`). Caller passes the binding count to `loadPipeline`. Buffer lifetimes are the caller's responsibility: a `Buffer` must outlive any dispatch that references it.

`dispatch` is synchronous and allocates a fresh descriptor pool + command buffer per call, then waits for queue idle. Fine for one-shots; in a tight loop the per-call Vulkan object churn will dominate. Reuse-across-dispatches is a non-goal for now.
