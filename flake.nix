{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};

      # Runtime: loader uses these to find the MoltenVK ICD and validation layers.
      vulkanRuntimeEnv = {
        VK_ICD_FILENAMES = "${pkgs.moltenvk}/share/vulkan/icd.d/MoltenVK_icd.json";
        VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
      };

      # Build: build.zig consumes these to find headers and link the loader.
      vulkanBuildEnv = {
        VULKAN_SDK = "${pkgs.vulkan-headers}";
        VK_LOADER_LIB = "${pkgs.vulkan-loader}/lib/libvulkan.dylib";
      };

      vulkanEnv = vulkanRuntimeEnv // vulkanBuildEnv;

      vulkanInputs = [
        pkgs.vulkan-headers
        pkgs.vulkan-loader
        pkgs.vulkan-validation-layers
        pkgs.vulkan-tools
        pkgs.moltenvk
        pkgs.spirv-tools
        pkgs.spirv-cross
        pkgs.glslang
      ];

      # Single shell: LLVM/cmake/ninja to build the patched vendor/zig, plus
      # the Vulkan stack. The patched zig (once built) handles both host and
      # kernel builds, so there's no separate "user" shell. cmake builds zig
      # from the bundled zig2.c, so we don't need a bootstrap zig on PATH.
      moltenShell = pkgs.mkShell (
        vulkanEnv
        // {
          # LLVM .td source for scripts/regen-cpu-features.sh. Matches the
          # linked LLVM, so no manual version pin to keep in sync.
          LLVM_SRC = "${pkgs.llvmPackages_22.llvm.monorepoSrc}";
          LLVM_VERSION = pkgs.llvmPackages_22.llvm.version;

          buildInputs = vulkanInputs ++ [
            pkgs.cmake
            pkgs.ninja
            pkgs.llvmPackages_22.llvm.dev
            pkgs.llvmPackages_22.lld
            pkgs.llvmPackages_22.libclang
            pkgs.libxml2
            pkgs.zlib
          ];

          shellHook = ''
            # Walk up from $PWD looking for the flake root (so the shell works
            # whether you ran `nix develop` from the repo root or a subdir).
            # We track the working tree, not the immutable /nix/store copy.
            __molten_root="$PWD"
            while [ "$__molten_root" != "/" ] && [ ! -f "$__molten_root/flake.nix" ]; do
              __molten_root="$(dirname "$__molten_root")"
            done
            if [ -f "$__molten_root/flake.nix" ]; then
              PATCHED_ZIG_BIN="$__molten_root/vendor/zig/build/stage3/bin"
              if [ -x "$PATCHED_ZIG_BIN/zig" ]; then
                export PATH="$PATCHED_ZIG_BIN:$PATH"
              fi
            fi
            unset __molten_root

            if [ -t 1 ]; then
              echo "=== molten-zig dev shell ==="
              if [ -n "''${PATCHED_ZIG_BIN:-}" ] && [ -x "$PATCHED_ZIG_BIN/zig" ]; then
                echo "zig               $PATCHED_ZIG_BIN/zig ($($PATCHED_ZIG_BIN/zig version))"
              else
                echo "zig               not built yet - run scripts/build-zig.sh"
              fi
              echo "vulkan-loader     ${pkgs.vulkan-loader.version}"
              echo "moltenvk          ${pkgs.moltenvk.version}"
              echo "spirv-tools       ${pkgs.spirv-tools.version}"
              echo "spirv-cross       ${pkgs.spirv-cross.version}"
              echo "glslang           ${pkgs.glslang.version}"
              echo "llvm              ${pkgs.llvmPackages_22.llvm.version}"
            fi
          '';
        }
      );
    in
    {
      formatter.${system} = pkgs.nixfmt;

      devShells.${system} = {
        default = moltenShell;
      };
    };
}
