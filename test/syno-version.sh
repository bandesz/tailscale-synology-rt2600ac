#!/bin/sh
# The download URL is derived from Tailscale's DSM 7 version mapping.
set -eu

cd "$(dirname "$0")/.."

check() {
    got=$(sh build-srm-spk.sh --syno-version "$1")
    if [ "$got" != "$2" ]; then
        echo "$1 current: expected $2, got $got" >&2
        exit 1
    fi
    got=$(sh build-srm-spk.sh --syno-version-legacy "$1")
    if [ "$got" != "$3" ]; then
        echo "$1 legacy: expected $3, got $got" >&2
        exit 1
    fi
}

# Current numbering matches pkgs.tailscale.com for 1.82.5 and 1.104.7.
# 1.48.0 is published under the older numbering.
check 1.104.7 700104007 7000104007
check v1.104.7 700104007 7000104007
check 1.48.0 700048000 7000048000
check 1.82.5 700082005 7000082005

if sh build-srm-spk.sh --syno-version 1.2 >/dev/null 2>&1; then
    echo "accepted a version without a patch number" >&2
    exit 1
fi

echo "syno version mapping ok"
