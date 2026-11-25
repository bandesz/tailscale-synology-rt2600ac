#!/bin/sh
# Build every row in srm/targets. Each invocation gets that row's SRM_ARCH.
# Usage: scripts/build-each.sh [version]
set -eu

cd "$(dirname "$0")/.."

while read -r arch _model; do
    [ -n "$arch" ] || continue
    SRM_ARCH=$arch sh build-srm-spk.sh "$@"
done < srm/targets
