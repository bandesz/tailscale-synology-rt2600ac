#!/bin/sh
# Build the SRM package and attach it to a GitHub release.
#
# Usage: scripts/release.sh [version]
#   version  Tailscale release, such as 1.104.7. When omitted, a GitHub
#            Actions tag named v1.2.3 supplies the version. Otherwise the
#            latest stable Tailscale release is packaged.
#
# Requires the GitHub CLI, authenticated with permission to create releases
# in this repository. Actions sets GH_TOKEN from github.token.
set -eu

cd "$(dirname "$0")/.."

version=${1:-${TAILSCALE_VERSION:-}}
if [ -z "$version" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
    case "$GITHUB_REF_NAME" in
        v[0-9]*) version=${GITHUB_REF_NAME#v} ;;
    esac
fi

if [ -n "$version" ]; then
    sh build-srm-spk.sh "$version"
else
    sh build-srm-spk.sh
fi

spk=$(cat dist/latest-spk-path)
if [ ! -f "$spk" ]; then
    echo "build did not produce ${spk}" >&2
    exit 1
fi

# tailscale-ipq806x-1.104.7-700104007-srm1.3.spk
base=$(basename "$spk")
tailscale_version=$(printf '%s\n' "$base" | sed -n 's/^tailscale-ipq806x-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)-.*/\1/p')
if [ -z "$tailscale_version" ]; then
    echo "could not read the Tailscale version from ${base}" >&2
    exit 1
fi
tag="v${tailscale_version}"

if ! command -v gh >/dev/null 2>&1; then
    echo "built ${spk}" >&2
    echo "install the GitHub CLI and authenticate, then rerun to publish ${tag}" >&2
    exit 1
fi

notes=$(cat <<EOF
Unofficial Tailscale ${tailscale_version} package for the Synology RT2600ac (SRM 1.3, arch ipq806x).

The binaries are Tailscale's armv7 DSM 7 build. This repository only repackages them so Package Center on SRM accepts the package.

## Install

1. In Package Center, set the trust level to **Any publisher**. The package is unsigned. Synology does not publish a key for third-party packages.
2. Open Package Center, choose Manual Install, and select \`${base}\`.
3. Start Tailscale.
4. Open it from the SRM main menu, or browse to \`http://<router>:8000/webman/3rdparty/Tailscale/index.cgi/\`.

On a router, turn Tailscale DNS off after logging in, or the router's own resolver is replaced:

\`\`\`
/var/packages/Tailscale/target/bin/tailscale set --accept-dns=false
\`\`\`
EOF
)

if gh release view "$tag" >/dev/null 2>&1; then
    gh release upload "$tag" "$spk" --clobber
else
    gh release create "$tag" "$spk" \
        --title "Tailscale ${tailscale_version} for RT2600ac SRM 1.3" \
        --notes "$notes"
fi

echo "published ${base} on ${tag}"
