{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};

      # Pinned zig 0.16.0 binary for the default shell.
      zigBin = pkgs.stdenvNoCC.mkDerivation {
        pname = "zig";
        version = "0.16.0";
        src = pkgs.fetchurl {
          url = "https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz";
          sha256 = "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489";
        };
        dontConfigure = true;
        dontBuild = true;
        dontFixup = true;
        installPhase = ''
          mkdir -p $out/bin $out/lib
          cp -r lib/* $out/lib/
          cp zig $out/bin/zig
        '';
      };

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
        pkgs.glslang
      ];

      versionBanner = zigPkg: ''
        if [ -t 1 ]; then
          echo "zig                $(${zigPkg}/bin/zig version 2>/dev/null || echo "(not built yet - run: ./scripts/build-zig.sh)")"
          echo "vulkan-loader      ${pkgs.vulkan-loader.version}"
          echo "vulkan-headers     ${pkgs.vulkan-headers.version}"
          echo "validation-layers  ${pkgs.vulkan-validation-layers.version}"
          echo "moltenvk           ${pkgs.moltenvk.version}"
          echo "spirv-tools        ${pkgs.spirv-tools.version}"
          echo "glslang            ${pkgs.glslang.version}"
        fi
      '';
    in
    {
      formatter.${system} = pkgs.nixfmt;

      devShells.${system} = {
        # Default shell: prebuilt zig 0.16.0, no LLVM toolchain.
        default = pkgs.mkShell (
          vulkanEnv
          // {
            buildInputs = [ zigBin ] ++ vulkanInputs;
            shellHook = versionBanner zigBin;
          }
        );

        # zig-dev shell: toolchain to build the patched zig from vendor/zig.
        # Run scripts/build-zig.sh inside this shell.
        zig-dev = pkgs.mkShell (
          vulkanEnv
          // {
            buildInputs = vulkanInputs ++ [
              zigBin # bootstrap compiler
              pkgs.cmake
              pkgs.ninja
              pkgs.llvmPackages_22.llvm.dev
              pkgs.llvmPackages_22.lld
              pkgs.llvmPackages_22.libclang
              pkgs.libxml2
              pkgs.zlib
            ];

            shellHook = ''
              # Resolved against $PWD so it tracks the working tree, not /nix/store.
              export PATCHED_ZIG="$PWD/vendor/zig/build/stage3/bin/zig"
              if [ -t 1 ]; then
                echo "=== molten-zig zig-dev shell ==="
                echo "bootstrap zig (0.16.0): ${zigBin}/bin/zig"
                if [ -x "$PATCHED_ZIG" ]; then
                  echo "patched zig:            $PATCHED_ZIG ($($PATCHED_ZIG version))"
                else
                  echo "patched zig:            not built yet - run scripts/build-zig.sh"
                fi
                echo "vulkan-loader      ${pkgs.vulkan-loader.version}"
                echo "moltenvk           ${pkgs.moltenvk.version}"
                echo "spirv-tools        ${pkgs.spirv-tools.version}"
                echo "glslang            ${pkgs.glslang.version}"
                echo "llvm               ${pkgs.llvmPackages_22.llvm.version}"
              fi
            '';
          }
        );
      };
    };
}
