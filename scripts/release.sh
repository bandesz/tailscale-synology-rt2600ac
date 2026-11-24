#!/bin/sh
# Build both SRM targets and attach them to one GitHub release.
# Usage: scripts/release.sh [version]
# RELEASE_DRY_RUN=1 builds both packages and prints notes without invoking gh.
set -eu

cd "$(dirname "$0")/.."

case "${RELEASE_DRY_RUN:-0}" in
    0|1) ;;
    *)
        echo "RELEASE_DRY_RUN must be 0 or 1" >&2
        exit 1
        ;;
esac

version=${1:-${TAILSCALE_VERSION:-}}
if [ -z "$version" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
    case "$GITHUB_REF_NAME" in
        v[0-9]*) version=${GITHUB_REF_NAME#v} ;;
    esac
fi

if [ -n "$version" ]; then
    SRM_ARCH=ipq806x sh build-srm-spk.sh "$version"
else
    SRM_ARCH=ipq806x sh build-srm-spk.sh
fi

rt_spk=$(cat dist/latest-spk-path)
if [ ! -f "$rt_spk" ]; then
    echo "build did not produce ${rt_spk}" >&2
    exit 1
fi

base=$(basename "$rt_spk")
tailscale_version=$(printf '%s\n' "$base" |
    sed -n 's/^tailscale-ipq806x-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)-.*/\1/p')
if [ -z "$tailscale_version" ]; then
    echo "could not read the Tailscale version from ${base}" >&2
    exit 1
fi

# Pin the second build to the version resolved by the first.
SRM_ARCH=hawkeye sh build-srm-spk.sh "$tailscale_version"
wrx_spk=$(cat dist/latest-spk-path)
expected_wrx="dist/$(printf '%s\n' "$base" | sed 's/^tailscale-ipq806x-/tailscale-hawkeye-/')"
if [ "$wrx_spk" != "$expected_wrx" ] || [ ! -f "$wrx_spk" ]; then
    echo "WRX560 build did not produce expected package ${expected_wrx}" >&2
    exit 1
fi

tag="v${tailscale_version}"
notes=$(cat <<EOF
Unofficial Tailscale ${tailscale_version} packages for Synology SRM 1.3:

- RT2600ac: $(basename "$rt_spk") (ipq806x)
- WRX560: $(basename "$wrx_spk") (hawkeye)

The binaries are the upstream Tailscale armv7 DSM 7 build, repackaged for SRM.

## Install

1. In Package Center, set the trust level to Any publisher.
2. Choose Manual Install and select the SPK matching your router model.
3. Start Tailscale and open its web UI from the SRM main menu.
4. Log in if this is a new installation.

Starting the package disables Tailscale DNS acceptance so the router keeps
its own resolver. LAN and exit-node advertisements follow the saved
installation choices and require approval in the Tailscale admin console.

## WRX560 testing

Package installation, same-version upgrade, service stop/start, unattended
reboot reconnection, SRM main-menu web UI access, and DERP peer connectivity
were tested on SRM 1.3.2-9366 Update 3 with Tailscale 1.104.7.

Testing used attached USB storage. Operation without it is not established.
Package Center did not show an Open button; use the SRM main-menu entry.
Reconnection requires a correct system clock.
Direct peer connectivity and subnet/exit-node forwarding were not verified.
See README.md for the testing scope and limitations.
EOF
)

if [ "${RELEASE_DRY_RUN:-0}" = 1 ]; then
    printf 'Dry run: would publish %s\nAssets:\n%s\n%s\n\n%s\n' \
        "$tag" "$rt_spk" "$wrx_spk" "$notes"
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "install and authenticate GitHub CLI to publish ${tag}" >&2
    exit 1
fi

if gh release view "$tag" >/dev/null 2>&1; then
    gh release upload "$tag" "$rt_spk" "$wrx_spk" --clobber
else
    gh release create "$tag" "$rt_spk" "$wrx_spk" \
        --title "Tailscale ${tailscale_version} for Synology SRM 1.3" \
        --notes "$notes"
fi

printf 'Published both SRM packages on %s\n' "$tag"
