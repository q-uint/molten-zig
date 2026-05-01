#!/usr/bin/env bash
# Fast incremental rebuild of the patched zig (dev=spirv only).
# Requires stage3 zig from build-zig.sh. Output: vendor/zig/zig-out/bin/zig.
set -euo pipefail

cd "$(dirname "$0")/.."
ZIGDIR="$PWD/vendor/zig"
STAGE3="$ZIGDIR/build/stage3/bin/zig"

if [ ! -x "$STAGE3" ]; then
  echo "error: stage3 zig missing at $STAGE3 - run scripts/build-zig.sh first"
  exit 1
fi

cd "$ZIGDIR"
"$STAGE3" build -Ddev=spirv -Doptimize=Debug
echo "==> $ZIGDIR/zig-out/bin/zig built"
