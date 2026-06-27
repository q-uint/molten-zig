#!/usr/bin/env bash
# Regenerate vendor/zig/lib/std/Target/<arch>.zig from LLVM .td files.
#
# Run inside `nix develop` (provides llvm-tblgen and $LLVM_SRC, the LLVM
# monorepo source matching the linked LLVM). Stage3 zig must already be
# built (scripts/build-zig.sh).
#
# Usage: scripts/regen-cpu-features.sh [arch_filter]
# Examples:
#   scripts/regen-cpu-features.sh           # all targets
#   scripts/regen-cpu-features.sh spirv     # one arch
set -euo pipefail

cd "$(dirname "$0")/.."
ZIGDIR="$PWD/vendor/zig"
LLVMSRC="${LLVM_SRC:-}"
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
if [ -z "$LLVMSRC" ] || [ ! -d "$LLVMSRC/llvm/lib/Target" ]; then
  echo "error: LLVM_SRC unset or missing llvm/lib/Target - run inside: nix develop"
  exit 1
fi

echo "==> using LLVM source ${LLVM_VERSION:-?} at $LLVMSRC"

cd "$ZIGDIR"
"$STAGE3" build-exe tools/update_cpu_features.zig -OReleaseFast
"$TOOL" "$TBLGEN" "$LLVMSRC" "$ZIGDIR" "${1:-}"
rm -f "$TOOL" "$TOOL.o"

echo "==> regenerated lib/std/Target/${1:-<all>}.zig"
