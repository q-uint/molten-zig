#!/usr/bin/env bash
# Regenerate vendor/zig/lib/std/Target/<arch>.zig from LLVM .td files.
#
# Run inside `nix develop` (needs llvm-tblgen). Stage3 zig must already
# be built (scripts/build-zig.sh). The vendor/llvm-project submodule must
# be initialised:
#   git submodule update --init --recursive vendor/llvm-project
#
# Usage: scripts/regen-cpu-features.sh [arch_filter]
# Examples:
#   scripts/regen-cpu-features.sh           # all targets
#   scripts/regen-cpu-features.sh spirv     # one arch
set -euo pipefail

# Last regenerated against this LLVM tag. Bump when vendor/llvm-project moves.
EXPECTED_LLVM_TAG="llvmorg-22.1.2"

cd "$(dirname "$0")/.."
ZIGDIR="$PWD/vendor/zig"
LLVMSRC="$PWD/vendor/llvm-project"
STAGE3="$ZIGDIR/build/stage3/bin/zig"
TBLGEN="$(command -v llvm-tblgen || true)"
TOOL="$ZIGDIR/update_cpu_features"

if [ ! -x "$STAGE3" ]; then
  echo "error: stage3 zig missing at $STAGE3 - run scripts/build-zig.sh first"
  exit 1
fi
if [ -z "$TBLGEN" ]; then
  echo "error: llvm-tblgen not on PATH - run inside: nix develop"
  exit 1
fi
if [ ! -d "$LLVMSRC/llvm/lib/Target" ]; then
  echo "error: vendor/llvm-project not initialised - run:"
  echo "  git submodule update --init --recursive vendor/llvm-project"
  exit 1
fi

ACTUAL_LLVM_TAG="$(git -C "$LLVMSRC" describe --tags --exact-match 2>/dev/null || echo unknown)"
if [ "$ACTUAL_LLVM_TAG" != "$EXPECTED_LLVM_TAG" ]; then
  echo "warning: vendor/llvm-project at $ACTUAL_LLVM_TAG, script expects $EXPECTED_LLVM_TAG"
fi

cd "$ZIGDIR"
"$STAGE3" build-exe tools/update_cpu_features.zig -OReleaseFast
"$TOOL" "$TBLGEN" "$LLVMSRC" "$ZIGDIR" "${1:-}"
rm -f "$TOOL" "$TOOL.o"

echo "==> regenerated lib/std/Target/${1:-<all>}.zig"
