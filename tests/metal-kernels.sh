#!/bin/bash
# Runs the Metal patch's two kernels on the CPU against the fork's CPU implementation, on any machine with a C++20
# compiler: the kernels and their argument structs come out of the patch itself, so this tests what setup applies.
#
#   tests/metal-kernels.sh [CXX]     CXX: the compiler, c++ by default
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
patch="$here/../patches/0001-metal-mhc-route-and-merge.patch"
cxx=${1:-c++}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# The lines the patch adds to one file
added() { awk -v f="a/$1" '/^diff --git/ { in_f = ($3 == f) } in_f && /^\+/ && !/^\+\+\+/ { print substr($0, 2) }' "$patch"; }

{ echo '#pragma once'; echo '#include <cstdint>'; added ggml/src/ggml-metal/ggml-metal-impl.h; } > "$out/mhc_kargs.h"
# The threadgroup memory's attribute has no C++ equivalent, and the shim makes "threadgroup" empty
added ggml/src/ggml-metal/kernels/misc.metal | sed 's/\[\[threadgroup(0)\]\]//' > "$out/mhc_kernels.metal.inc"
grep -q kernel_mhc_route_f32 "$out/mhc_kernels.metal.inc" || { echo "no kernels found in $patch" >&2; exit 1; }

"$cxx" -std=c++20 -O2 -pthread -Wno-unknown-attributes -I "$out" "$here/metal_kernels.cpp" -o "$out/metal_kernels"
"$out/metal_kernels"
