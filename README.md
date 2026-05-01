# molten-zig

Compute kernels written in Zig, lowered to SPIR-V via the self-hosted backend, dispatched on Apple Silicon GPUs through Vulkan/MoltenVK.

Apple Silicon only. Compute only. Early-stage learning project.

## Layout

- `host.zig` - minimal Vulkan host: loads a `.spv`, binds two storage buffers, dispatches, verifies output.
- `probe.zig` - Zig kernel; smoke-tests the patched SPIR-V backend.
- `shader.comp` - equivalent GLSL kernel; reference for parity checks.
- `vendor/zig` - submodule, patched compiler with the SPIR-V changes.
- `scripts/build-zig.sh` - first-time stage3 build of the patched compiler.
- `scripts/rebuild-zig.sh` - fast incremental rebuild after compiler edits.

## Usage

```sh
nix develop                     # default shell (prebuilt zig 0.16.0)
nix develop .#zig-dev           # toolchain shell for building vendor/zig
scripts/build-zig.sh            # first-time stage3 build (~30 min)
scripts/rebuild-zig.sh          # subsequent rebuilds (~30 s)
zig build all                   # compile both shaders, validate, dispatch both
```
