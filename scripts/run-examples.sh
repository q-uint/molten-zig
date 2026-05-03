#!/usr/bin/env bash
# Run `zig build all` in every example. Each example is an independent
# package with its own build.zig consuming molten as a dependency.
set -euo pipefail

cd "$(dirname "$0")/.."
ZIG="${ZIG:-$PWD/vendor/zig/build/stage3/bin/zig}"

if [ ! -x "$ZIG" ]; then
  echo "error: zig missing at $ZIG - run scripts/build-zig.sh first, or set ZIG=<path>"
  exit 1
fi

EXAMPLES=(chain reduce matrix_transpose vector_multiply wg_reduce)

for ex in "${EXAMPLES[@]}"; do
  echo "==> examples/$ex"
  ( cd "examples/$ex" && "$ZIG" build all )
done
