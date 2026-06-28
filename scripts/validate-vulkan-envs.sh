#!/usr/bin/env bash
# Validate a SPIR-V module against every major Vulkan env.
#
# Our kernels target SPIR-V 1.4. vulkan1.0 (SPIR-V 1.0) and vulkan1.1
# (SPIR-V 1.3) cannot load a 1.4 binary at all, so they are EXPECTED to fail
# on the version ceiling - but only on that. A failure there for any other
# reason, or any failure at 1.2/1.3/1.4, fails this script.
set -u

spv="$1"
if [ -z "${spv:-}" ]; then
    echo "usage: $0 <module.spv>" >&2
    exit 2
fi

must_pass="vulkan1.2 vulkan1.3 vulkan1.4"
expect_ceiling="vulkan1.0 vulkan1.1"
rc=0

echo "validate $(basename "$spv"):"

for env in $must_pass; do
    if out=$(spirv-val --target-env "$env" "$spv" 2>&1); then
        echo "  $env: PASS"
    else
        echo "  $env: FAIL (must pass)" >&2
        echo "$out" | sed 's/^/    /' >&2
        rc=1
    fi
done

# 1.0/1.1 may reject a SPIR-V 1.4 module on the version ceiling (our Zig
# kernels) or accept a lower-versioned one (glslang output). Both are fine;
# only a non-version failure is a real defect.
for env in $expect_ceiling; do
    out=$(spirv-val --target-env "$env" "$spv" 2>&1)
    if [ -z "$out" ]; then
        echo "  $env: PASS"
    elif echo "$out" | grep -q "Invalid SPIR-V binary version"; then
        echo "  $env: version-ceiling fail (ok)"
    else
        echo "  $env: FAIL for a non-version reason" >&2
        echo "$out" | sed 's/^/    /' >&2
        rc=1
    fi
done

exit $rc
