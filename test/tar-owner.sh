#!/bin/sh
# The SPK is a ustar archive whose members are owned by root. macOS bsdtar
# and GNU tar (CI) need different flags to record that.
set -eu

cd "$(dirname "$0")/.."

# shellcheck source=build-srm-spk.sh
. ./build-srm-spk.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo hi >"$tmp/file"
pack_ustar -cf "$tmp/out.tar" -C "$tmp" file

field() {
    dd if="$tmp/out.tar" bs=1 skip="$1" count="$2" 2>/dev/null | tr -d ' \0'
}

uid=$(field 108 7)
gid=$(field 116 7)
uname=$(field 265 4)
gname=$(field 297 4)
magic=$(field 257 5)

case "$uid" in
    *[!0]*|'') echo "uid field is not 0: ${uid}" >&2; exit 1 ;;
esac
case "$gid" in
    *[!0]*|'') echo "gid field is not 0: ${gid}" >&2; exit 1 ;;
esac
if [ "$uname" != root ] || [ "$gname" != root ]; then
    echo "owner name is ${uname}:${gname}, expected root:root" >&2
    exit 1
fi
if [ "$magic" != ustar ]; then
    echo "archive magic is ${magic}, expected ustar" >&2
    exit 1
fi

echo "tar owner ok"
