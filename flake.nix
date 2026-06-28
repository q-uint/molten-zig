{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f system);

      mkSpritzShell =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          isDarwin = pkgs.stdenv.isDarwin;
          arch = lib.head (lib.splitString "-" system);

          # Vulkan ICD (driver). macOS has no native Vulkan, so we ship
          # MoltenVK (Vulkan-on-Metal). Linux ships mesa's lavapipe software
          # rasterizer, so the shell works headless / in CI without a
          # configured GPU - matching how the macOS shell is self-contained.
          icd =
            if isDarwin then
              "${pkgs.moltenvk}/share/vulkan/icd.d/MoltenVK_icd.json"
            else
              "${pkgs.mesa}/share/vulkan/icd.d/lvp_icd.${arch}.json";

          # build.zig only consumes this for its directory component, so the
          # platform-specific extension (.dylib vs .so) just needs to resolve.
          loaderLib =
            if isDarwin then
              "${pkgs.vulkan-loader}/lib/libvulkan.dylib"
            else
              "${pkgs.vulkan-loader}/lib/libvulkan.so";

          driverPkg = if isDarwin then pkgs.moltenvk else pkgs.mesa;
          driverLabel = if isDarwin then "moltenvk" else "mesa (lavapipe)";

          # Runtime: loader uses these to find the ICD and validation layers.
          vulkanRuntimeEnv = {
            VK_ICD_FILENAMES = icd;
            VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
          };

          # Build: build.zig consumes these to find headers and link the loader.
          vulkanBuildEnv = {
            VULKAN_SDK = "${pkgs.vulkan-headers}";
            VK_LOADER_LIB = loaderLib;
          };

          vulkanEnv = vulkanRuntimeEnv // vulkanBuildEnv;

          vulkanInputs = [
            pkgs.vulkan-headers
            pkgs.vulkan-loader
            pkgs.vulkan-validation-layers
            pkgs.vulkan-tools
            driverPkg
            pkgs.spirv-tools
            pkgs.spirv-cross
            pkgs.glslang
          ];
        in
        # Single shell: LLVM/cmake/ninja to build the patched vendor/zig, plus
        # the Vulkan stack. The patched zig (once built) handles both host and
        # kernel builds, so there's no separate "user" shell. cmake builds zig
        # from the bundled zig2.c, so we don't need a bootstrap zig on PATH.
        pkgs.mkShell (
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
              __spritz_root="$PWD"
              while [ "$__spritz_root" != "/" ] && [ ! -f "$__spritz_root/flake.nix" ]; do
                __spritz_root="$(dirname "$__spritz_root")"
              done
              if [ -f "$__spritz_root/flake.nix" ]; then
                PATCHED_ZIG_BIN="$__spritz_root/vendor/zig/build/stage3/bin"
                if [ -x "$PATCHED_ZIG_BIN/zig" ]; then
                  export PATH="$PATCHED_ZIG_BIN:$PATH"
                fi
              fi
              unset __spritz_root

              if [ -t 1 ]; then
                echo "=== spritz-zig dev shell ==="
                if [ -n "''${PATCHED_ZIG_BIN:-}" ] && [ -x "$PATCHED_ZIG_BIN/zig" ]; then
                  echo "zig               $PATCHED_ZIG_BIN/zig ($($PATCHED_ZIG_BIN/zig version))"
                else
                  echo "zig               not built yet - run scripts/build-zig.sh"
                fi
                echo "vulkan-loader     ${pkgs.vulkan-loader.version}"
                echo "vulkan driver     ${driverLabel} ${driverPkg.version}"
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
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      devShells = forAllSystems (system: {
        default = mkSpritzShell system;
      });
    };
}
