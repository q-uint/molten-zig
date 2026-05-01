#!/usr/bin/env bash
# First-time build of the patched zig from vendor/zig.
# Run inside `nix develop .#zig-dev`.
set -euo pipefail

cd "$(dirname "$0")/.."
ZIGDIR="$PWD/vendor/zig"
BUILD="$ZIGDIR/build"

if ! command -v cmake >/dev/null || ! command -v ninja >/dev/null; then
  echo "error: cmake or ninja missing - run inside: nix develop .#zig-dev"
  exit 1
fi

mkdir -p "$BUILD"
cd "$BUILD"

if [ ! -f CMakeCache.txt ]; then
  cmake .. \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Debug \
    -DZIG_STATIC_LLVM=ON \
    -DZIG_TARGET_MCPU=baseline \
    -DCMAKE_INSTALL_PREFIX="$BUILD/stage3" \
    -DCMAKE_SKIP_BUILD_RPATH=ON
fi

ninja install
"$BUILD/stage3/bin/zig" version
