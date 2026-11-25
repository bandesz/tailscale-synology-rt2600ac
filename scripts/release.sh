#!/bin/sh
# Build every target in srm/targets and attach the packages to one GitHub release.
# Usage: scripts/release.sh [version]
# RELEASE_DRY_RUN=1 builds the packages and prints notes without invoking gh.
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

set --
first=1
first_arch=
base=
tailscale_version=
model_notes=

while read -r arch model; do
    [ -n "$arch" ] || continue
    if [ "$first" -eq 1 ]; then
        if [ -n "$version" ]; then
            SRM_ARCH=$arch sh build-srm-spk.sh "$version"
        else
            SRM_ARCH=$arch sh build-srm-spk.sh
        fi
        first=0
        first_arch=$arch
        spk=$(cat dist/latest-spk-path)
        if [ ! -f "$spk" ]; then
            echo "build did not produce ${spk}" >&2
            exit 1
        fi
        base=$(basename "$spk")
        tailscale_version=$(printf '%s\n' "$base" |
            sed -n "s/^tailscale-${arch}-\\([0-9][0-9]*\\.[0-9][0-9]*\\.[0-9][0-9]*\\)-.*/\\1/p")
        if [ -z "$tailscale_version" ]; then
            echo "could not read the Tailscale version from ${base}" >&2
            exit 1
        fi
    else
        SRM_ARCH=$arch sh build-srm-spk.sh "$tailscale_version"
        spk=$(cat dist/latest-spk-path)
        expected="dist/$(printf '%s\n' "$base" | sed "s/^tailscale-${first_arch}-/tailscale-${arch}-/")"
        if [ "$spk" != "$expected" ] || [ ! -f "$spk" ]; then
            echo "${model} build did not produce expected package ${expected}" >&2
            exit 1
        fi
    fi
    set -- "$@" "$spk"
    model_notes="${model_notes}
- ${model}: $(basename "$spk") (${arch})"
done < srm/targets

tag="v${tailscale_version}"
notes=$(cat <<EOF
Unofficial Tailscale ${tailscale_version} packages for Synology SRM 1.3:
${model_notes}

The binaries are the upstream Tailscale armv7 DSM 7 build, repackaged for SRM.

## Install

1. In Package Center, set the trust level to Any publisher.
2. Choose Manual Install and select the SPK matching your router model.
3. Start Tailscale.
4. Open it from the SRM main menu, or browse to http://<router>:8000/webman/3rdparty/Tailscale/index.cgi/.

Starting the package disables Tailscale DNS acceptance so the router keeps
its own resolver. LAN and exit-node advertisements follow the saved
installation choices and require approval in the Tailscale admin console.

The WRX560 needs a storage volume. Operation without USB storage is not
established. Package Center may not show an Open button; use the SRM main
menu or the address above. Reconnection requires a correct system clock.
See README.md for the testing scope and limitations.
EOF
)

if [ "${RELEASE_DRY_RUN:-0}" = 1 ]; then
    printf 'Dry run: would publish %s\nAssets:\n' "$tag"
    printf '%s\n' "$@"
    printf '\n%s\n' "$notes"
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "install and authenticate GitHub CLI to publish ${tag}" >&2
    exit 1
fi

if gh release view "$tag" >/dev/null 2>&1; then
    gh release upload "$tag" "$@" --clobber
else
    gh release create "$tag" "$@" \
        --title "Tailscale ${tailscale_version} for Synology SRM 1.3" \
        --notes "$notes"
fi

printf 'Published the SRM packages on %s\n' "$tag"
