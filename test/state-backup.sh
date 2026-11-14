#!/bin/sh
# An upgrade on SRM removes /var/packages/Tailscale/var. The node key has to
# be copied out before that and put back afterwards.
set -eu

cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export SYNOPKG_PKGDEST="$tmp"
export SYNOPKG_PKGVAR="$tmp/var"
export SYNOPKG_PKGNAME=Tailscale
export SYNOPKG_TEMP_LOGFILE="$tmp/notes"
export STATE_BACKUP_DIR="$tmp/etc"
export SYNOPKG_TEMP_UPGRADE_FOLDER="$tmp/upgrade"
mkdir -p "$SYNOPKG_PKGVAR" "$STATE_BACKUP_DIR" "$SYNOPKG_TEMP_UPGRADE_FOLDER"
printf '%s\n' 'node-key' > "$SYNOPKG_PKGVAR/tailscaled.state"
: > "$SYNOPKG_TEMP_LOGFILE"

# shellcheck source=srm/preupgrade
sh ./srm/preupgrade

if [ "$(cat "$STATE_BACKUP_DIR/tailscaled.state")" != "node-key" ]; then
    echo "preupgrade did not keep the node key in the package etc directory" >&2
    exit 1
fi
if [ "$(cat "$SYNOPKG_TEMP_UPGRADE_FOLDER/tailscaled.state")" != "node-key" ]; then
    echo "preupgrade did not keep the node key in the upgrade folder" >&2
    exit 1
fi

rm -f "$SYNOPKG_PKGVAR/tailscaled.state"
# shellcheck source=srm/postupgrade
sh ./srm/postupgrade
if [ "$(cat "$SYNOPKG_PKGVAR/tailscaled.state")" != "node-key" ]; then
    echo "postupgrade did not restore the node key" >&2
    exit 1
fi

printf '%s\n' 'newer-key' > "$SYNOPKG_PKGVAR/tailscaled.state"
sh ./srm/postupgrade
if [ "$(cat "$SYNOPKG_PKGVAR/tailscaled.state")" != "newer-key" ]; then
    echo "postupgrade replaced a node key that was already there" >&2
    exit 1
fi

rm -f "$SYNOPKG_PKGVAR/tailscaled.state" "$SYNOPKG_TEMP_UPGRADE_FOLDER/tailscaled.state"
# shellcheck source=srm/start-stop-status
. ./srm/start-stop-status
restore_state
if [ "$(cat "$SYNOPKG_PKGVAR/tailscaled.state")" != "node-key" ]; then
    echo "start did not restore the node key from the package etc directory" >&2
    exit 1
fi

echo "node key survives an upgrade"
