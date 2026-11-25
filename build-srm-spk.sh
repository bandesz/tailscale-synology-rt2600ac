#!/bin/sh
# Build a Synology SRM 1.3 package from Tailscale's armv7 DSM 7 SPK.
#
# The DSM packages declare arch "armv7" and a DSM 6/7 minimum version, so
# SRM never accepts them. This writes a package Package Center can install
# on SRM 1.3: platform-specific arch, os_min_ver 1.3-9193, and the standard
# install/upgrade/start scripts. No signature is added. Synology does not
# publish a signing key, and the SRM packages that install on these routers
# are unsigned.
#
# Usage: [SRM_ARCH=<arch>] build-srm-spk.sh [version]
#   SRM_ARCH  Platform from srm/targets. Omit it to use the first row.
#   version   Tailscale release, such as 1.104.7. Omit it to use the latest
#             stable GitHub release. The armv7 DSM 7 SPK is downloaded from
#             https://pkgs.tailscale.com/stable/ and checked against the
#             published SHA-256.
#   --syno-version VERSION
#             Print the Synology build number for VERSION and exit.
#   --print-target VERSION
#             Print the model, SPK path, and INFO for VERSION, then exit.
set -eu

# Split MAJOR.MINOR.PATCH into the globals major, minor, and patch.
parse_version() {
    ver=${1#v}
    case "$ver" in
        *.*.*) ;;
        *)
            echo "version must look like 1.104.7, got ${ver}" >&2
            return 1
            ;;
    esac
    major=${ver%%.*}
    rest=${ver#*.}
    minor=${rest%%.*}
    patch=${rest#*.}
    case "$patch" in
        *.*)
            echo "version must look like 1.104.7, got ${ver}" >&2
            return 1
            ;;
    esac
    for part in "$major" "$minor" "$patch"; do
        case "$part" in
            ''|*[!0-9]*)
                echo "version must be numeric, got ${ver}" >&2
                return 1
                ;;
        esac
    done
}

# Tailscale's current DSM 7 sideload numbering. See version/mkversion:
# 70*10_000_000 + (major-1)*1_000_000 + minor*1_000 + patch.
syno_version() {
    parse_version "$1" || return 1
    echo $((70 * 10000000 + (major - 1) * 1000000 + minor * 1000 + patch))
}

# Numbering used by older Tailscale releases, such as 1.48.0.
syno_version_legacy() {
    parse_version "$1" || return 1
    echo $((7 * 1000000000 + (major - 1) * 1000000 + minor * 1000 + patch))
}

# srm/targets is one "<arch> <model>" row per line. The first row is the default.
resolve_srm_target() {
    targets=$(dirname "$0")/srm/targets
    srm_arch=${SRM_ARCH:-}
    router_model=
    allowed=
    while read -r arch model; do
        [ -n "$arch" ] || continue
        if [ -z "$allowed" ]; then
            allowed=$arch
        else
            allowed="${allowed} or ${arch}"
        fi
        if [ -z "$srm_arch" ]; then
            srm_arch=$arch
            router_model=$model
        elif [ "$arch" = "$srm_arch" ] && [ -z "$router_model" ]; then
            router_model=$model
        fi
    done <"$targets"
    if [ -z "$router_model" ]; then
        echo "unsupported SRM_ARCH: ${srm_arch}; use ${allowed}" >&2
        exit 1
    fi
}

srm_spk_path() {
    printf 'dist/tailscale-%s-%s-srm1.3.spk\n' "$1" "$2"
}

srm_info() {
    cat <<EOF
package="Tailscale"
version="${1}"
description="Unofficial Tailscale package for the Synology ${router_model} (SRM 1.3)."
displayname="Tailscale"
maintainer="synology-tailscale"
maintainer_url="https://github.com/tailscale/tailscale"
arch="${srm_arch}"
os_min_ver="1.3-9193"
dsmuidir="ui"
dsmappname="SYNO.SDS.Tailscale"
startstop_restart_services="nginx"
reloadui="yes"
EOF
}

if [ "${1:-}" = "--syno-version" ]; then
    syno_version "${2:?version required}"
    exit 0
fi
if [ "${1:-}" = "--syno-version-legacy" ]; then
    syno_version_legacy "${2:?version required}"
    exit 0
fi
if [ "${1:-}" = "--print-target" ]; then
    resolve_srm_target
    printf '%s\n' "$router_model"
    ver="${2:?version required}"
    syn=$(syno_version "$ver") || exit 1
    preview="${ver}-${syn}"
    srm_spk_path "$srm_arch" "$preview"
    srm_info "$preview"
    exit 0
fi

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Package Center reads WIZARD_UIFILES from the SPK root, not from package.tgz.
stage_wizard() {
    dest=$1
    mkdir -p "${dest}/WIZARD_UIFILES"
    cp srm/WIZARD_UIFILES/install_uifile srm/WIZARD_UIFILES/upgrade_uifile.sh \
        "${dest}/WIZARD_UIFILES/"
    chmod 755 "${dest}/WIZARD_UIFILES/upgrade_uifile.sh"
}

# Members must be uid 0 and uname root. macOS bsdtar records that with
# --uid and --uname. GNU tar rejects --uid; --owner=root sets both the
# numeric id and the name.
pack_ustar() {
    if tar --version 2>/dev/null | grep -q 'GNU tar'; then
        COPYFILE_DISABLE=1 tar --format ustar --owner=root --group=root "$@"
    else
        COPYFILE_DISABLE=1 tar --format ustar \
            --uid 0 --gid 0 --uname root --gname root \
            "$@"
    fi
}

latest_version() {
    curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: synology-tailscale" \
        https://api.github.com/repos/tailscale/tailscale/releases/latest \
        | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' \
        | head -n 1
}

# Download one candidate SPK. Returns 1 when that filename is not published.
download_candidate() {
    ver=$1
    syno=$2
    name="tailscale-armv7-${ver}-${syno}-dsm7.spk"
    url="https://pkgs.tailscale.com/stable/${name}"
    dest="cache/${name}"
    mkdir -p cache

    if ! curl -fsSL -o "${dest}.sha256" "${url}.sha256"; then
        rm -f "${dest}.sha256"
        return 1
    fi
    want=$(tr -d '[:space:]' <"${dest}.sha256")
    case "$want" in
        *[!0-9a-fA-F]*|'')
            echo "unexpected checksum from ${url}.sha256" >&2
            return 1
            ;;
    esac

    if [ -f "$dest" ] && [ "$(sha256_file "$dest")" = "$want" ]; then
        echo "using cached ${dest}" >&2
        printf '%s\n' "$dest"
        return 0
    fi

    echo "downloading ${url}" >&2
    curl -fL --retry 3 -o "${dest}.partial" "$url"
    mv "${dest}.partial" "$dest"
    got=$(sha256_file "$dest")
    if [ "$got" != "$want" ]; then
        echo "checksum mismatch for ${name}" >&2
        echo "expected ${want}" >&2
        echo "got      ${got}" >&2
        return 1
    fi
    printf '%s\n' "$dest"
}

download_spk() {
    ver=$1
    current=$(syno_version "$ver")
    legacy=$(syno_version_legacy "$ver")
    if download_candidate "$ver" "$current"; then
        return 0
    fi
    if [ "$legacy" != "$current" ] && download_candidate "$ver" "$legacy"; then
        return 0
    fi
    echo "could not download the armv7 DSM 7 package for ${ver}" >&2
    echo "check https://pkgs.tailscale.com/stable/?v=${ver}" >&2
    return 1
}

# Tests source this file for pack_ustar. Building runs only as a script.
if [ "${0##*/}" = "build-srm-spk.sh" ]; then
cd "$(dirname "$0")"

resolve_srm_target

version=${1:-${TAILSCALE_VERSION:-}}
if [ -z "$version" ]; then
    version=$(latest_version)
    if [ -z "$version" ]; then
        echo "could not read the latest Tailscale release" >&2
        exit 1
    fi
fi
version=${version#v}
src=$(download_spk "$version")

stage=$(mktemp -d "${TMPDIR:-/tmp}/tailscale-srm.XXXXXX")
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/conf" "$stage/scripts" "$stage/payload"
tar -xf "$src" -C "$stage" package.tgz PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG
tar -xzf "$stage/package.tgz" -C "$stage/payload"
elf_class=$(od -An -t u1 -j 4 -N 1 "$stage/payload/bin/tailscaled" | tr -d ' ')
if [ "$elf_class" != "1" ]; then
    echo "${router_model} needs the 32-bit arm package (ELF class ${elf_class})" >&2
    exit 1
fi

# SRM's desktop is already served under /webman/ (port 8000). Synology's
# application config says the menu url is "3rdparty/<package>/...", which
# resolves to /webman/3rdparty/... The DSM value starts with "webman/" and
# becomes /webman/webman/... on SRM. The CGI prefix stays /webman/3rdparty,
# because that is the path the browser actually requests.
cat >"$stage/payload/ui/config" <<'EOF'
{
	".url": {
		"SYNO.SDS.Tailscale": {
			"type": "url",
			"title": "Tailscale",
			"icon": "PACKAGE_ICON_256.PNG",
			"url": "3rdparty/Tailscale/index.cgi/",
			"urlTarget": "_syno_tailscale"
		}
	}
}
EOF
# Apache on SRM runs CGI as the web user. tailscaled only allows root or the
# operator to change prefs, so this entry is a setuid-root helper that execs
# "tailscale web -cgi" with the CGI environment intact. The start script sets
# the setuid bit; some package installers strip it from the archive.
rm -f "$stage/payload/ui/index.cgi"
(
    cd srm/cgiwrap
    CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 \
        go build -ldflags '-s -w' -o "$stage/payload/ui/index.cgi" .
)
chmod 755 "$stage/payload/ui" "$stage/payload/ui/index.cgi"
rm -f "$stage/package.tgz"
pack_ustar -czf "$stage/package.tgz" -C "$stage/payload" \
    bin conf ui
rm -rf "$stage/payload"

upstream_version=$(tar -xOf "$src" INFO | sed -n 's/^version="\(.*\)"$/\1/p')
if [ -z "$upstream_version" ]; then
    echo "could not read version from ${src}" >&2
    exit 1
fi

cp srm/privilege "$stage/conf/privilege"
cp srm/resource "$stage/conf/resource"
cp srm/start-stop-status srm/preinst srm/postinst srm/preuninst srm/postuninst \
    srm/preupgrade srm/postupgrade "$stage/scripts/"
chmod 755 "$stage/scripts/"*
stage_wizard "$stage"

# dsmuidir is where Package Center reads the menu config. The start script
# copies those files into /usr/syno/synoman/webman/3rdparty/, which is what
# Apache on port 8000 serves. dsmappname is the Open button.
srm_info "$upstream_version" >"$stage/INFO"

mkdir -p dist
out=$(srm_spk_path "$srm_arch" "$upstream_version")
rm -f "$out"
pack_ustar -cf "$out" -C "$stage" \
    INFO \
    PACKAGE_ICON.PNG \
    PACKAGE_ICON_256.PNG \
    package.tgz \
    conf \
    scripts \
    WIZARD_UIFILES

printf '%s\n' "$out" >dist/latest-spk-path
echo "built ${out}"
fi
