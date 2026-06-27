#!/usr/bin/env bash
# First-time build of the patched zig from vendor/zig.
# Run inside `nix develop`.
set -euo pipefail

cd "$(dirname "$0")/.."
ZIGDIR="$PWD/vendor/zig"
BUILD="$ZIGDIR/build"

if ! command -v cmake >/dev/null || ! command -v ninja >/dev/null; then
  echo "error: cmake or ninja missing - run inside: nix develop"
  exit 1
fi

mkdir -p "$BUILD"
cd "$BUILD"

# A CMakeCache pinned to a different source dir (moved/copied checkout) makes
# ninja fail confusingly; treat it as stale and reconfigure from scratch.
if [ -f CMakeCache.txt ] && ! grep -qxF "CMAKE_HOME_DIRECTORY:INTERNAL=$ZIGDIR" CMakeCache.txt; then
  echo "==> stale CMakeCache (source dir changed); reconfiguring"
  rm -rf CMakeCache.txt CMakeFiles
fi

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
