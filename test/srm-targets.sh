#!/bin/sh
# Target selection and the dual-package release stay in lockstep.
# The release script is exercised with a stand-in build so this test
# does not download an upstream SPK.
set -eu

cd "$(dirname "$0")/.."

fail() {
    echo "$1" >&2
    exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
echo invoked >>"${CURL_LOG:?}"
exit 99
EOF
chmod +x "$tmp/bin/curl"

if PATH="$tmp/bin:$PATH" CURL_LOG="$tmp/curl-log" \
    SRM_ARCH=nope sh build-srm-spk.sh 1.2.3 >"$tmp/arch-out" 2>"$tmp/arch-err"; then
    fail "accepted unsupported SRM_ARCH"
fi
if ! grep -F 'unsupported SRM_ARCH: nope' "$tmp/arch-err" >/dev/null; then
    fail "unsupported SRM_ARCH did not explain the failure"
fi
while read -r arch model; do
    [ -n "$arch" ] || continue
    if ! grep -F "$arch" "$tmp/arch-err" >/dev/null; then
        fail "unsupported SRM_ARCH did not list ${arch} (${model}) from srm/targets"
    fi
done < srm/targets
if [ -s "$tmp/curl-log" ]; then
    fail "unsupported SRM_ARCH tried to download an upstream SPK"
fi

got=$(SRM_ARCH=nope sh build-srm-spk.sh --syno-version 1.104.7)
if [ "$got" != 700104007 ]; then
    fail "SRM_ARCH leaked into --syno-version (got ${got})"
fi

# --print-target reports the model, SPK path, and INFO, then exits
# before any download. Expected rows come from srm/targets.
check_print() {
    arch=$1
    model=$2
    out=$3
    if ! printf '%s\n' "$out" | grep -Fx "$model" >/dev/null; then
        fail "--print-target omitted model ${model}"
    fi
    path="dist/tailscale-${arch}-9.9.9-srm1.3.spk"
    if ! printf '%s\n' "$out" | grep -Fx "$path" >/dev/null; then
        fail "--print-target omitted ${path}"
    fi
    desc="description=\"Unofficial Tailscale package for the Synology ${model} (SRM 1.3).\""
    if ! printf '%s\n' "$out" | grep -Fx "$desc" >/dev/null; then
        fail "--print-target INFO omitted the ${model} description"
    fi
    if ! printf '%s\n' "$out" | grep -Fx "arch=\"${arch}\"" >/dev/null; then
        fail "--print-target INFO omitted arch ${arch}"
    fi
    if [ -s "$tmp/curl-log" ]; then
        fail "--print-target tried to download an upstream SPK"
    fi
}

while read -r arch model; do
    [ -n "$arch" ] || continue
    : >"$tmp/curl-log"
    if ! out=$(PATH="$tmp/bin:$PATH" CURL_LOG="$tmp/curl-log" \
        SRM_ARCH="$arch" sh build-srm-spk.sh --print-target 9.9.9 \
        2>"$tmp/print-err"); then
        cat "$tmp/print-err" >&2
        fail "--print-target rejected ${arch}"
    fi
    check_print "$arch" "$model" "$out"
done < srm/targets

first_arch=
first_model=
while read -r arch model; do
    [ -n "$arch" ] || continue
    first_arch=$arch
    first_model=$model
    break
done < srm/targets
: >"$tmp/curl-log"
if ! out=$(PATH="$tmp/bin:$PATH" CURL_LOG="$tmp/curl-log" \
    env -u SRM_ARCH sh build-srm-spk.sh --print-target 9.9.9 \
    2>"$tmp/print-err"); then
    cat "$tmp/print-err" >&2
    fail "--print-target rejected the default target"
fi
check_print "$first_arch" "$first_model" "$out"

if ! grep -F 'srm/targets' build-srm-spk.sh >/dev/null; then
    fail "build script does not read srm/targets"
fi
if grep -F ':-ipq806x' build-srm-spk.sh >/dev/null; then
    fail "default arch is still hardcoded"
fi
if grep -F 'router_model=RT2600ac' build-srm-spk.sh >/dev/null \
    || grep -F 'router_model=WRX560' build-srm-spk.sh >/dev/null; then
    fail "build script still hardcodes router models"
fi
main=$(sed -n '/^if \[ "${0##\*\/}" = "build-srm-spk\.sh" \]; then$/,$p' build-srm-spk.sh)
preamble=$(sed -n '1,/^if \[ "${0##\*\/}" = "build-srm-spk\.sh" \]; then$/p' build-srm-spk.sh)
if [ -z "$main" ]; then
    fail "could not find the build-srm-spk.sh main block"
fi
for fn in resolve_srm_target srm_spk_path srm_info; do
    if ! printf '%s\n' "$preamble" | grep -F "${fn}()" >/dev/null; then
        fail "helper ${fn} is not defined beside the early exits"
    fi
    if ! printf '%s\n' "$main" | grep -F "${fn}" >/dev/null; then
        fail "build main block does not call ${fn}"
    fi
done
case "$main" in
    *'ipq806x)'*) fail "build main block still special-cases ipq806x" ;;
esac
case "$main" in
    *'hawkeye)'*) fail "build main block still special-cases hawkeye" ;;
esac

if grep -F 'tailscale-ipq806x-' scripts/release.sh >/dev/null; then
    fail "release script still parses a version with a fixed ipq806x prefix"
fi
if ! grep -F 'srm/targets' scripts/release.sh >/dev/null; then
    fail "release script does not read srm/targets"
fi
if ! grep -F 'done < srm/targets' scripts/release.sh >/dev/null; then
    fail "release script does not loop srm/targets by redirect"
fi
if grep -F 'srm/targets |' scripts/release.sh >/dev/null; then
    fail "release script loops srm/targets through a pipeline"
fi

if RELEASE_DRY_RUN=2 sh scripts/release.sh 9.9.9 >"$tmp/dry-out" 2>"$tmp/dry-err"; then
    fail "accepted RELEASE_DRY_RUN=2"
fi
if ! grep -F 'RELEASE_DRY_RUN must be 0 or 1' "$tmp/dry-err" >/dev/null; then
    fail "bad RELEASE_DRY_RUN did not explain the failure"
fi

mkdir -p "$tmp/scripts" "$tmp/srm"
cp scripts/release.sh "$tmp/scripts/release.sh"
cp srm/targets "$tmp/srm/targets"
cat >"$tmp/build-srm-spk.sh" <<'EOF'
#!/bin/sh
set -eu
printf '%s %s\n' "${SRM_ARCH:-unset}" "${1:-}" >>"${BUILD_LOG:?}"
arch=${SRM_ARCH:?}
lines=$(wc -l <"${BUILD_LOG}" | tr -d ' ')
if [ "$lines" -eq 1 ]; then
    ver=1.2.3
else
    ver=${1:?}
    if [ "$ver" != 1.2.3 ]; then
        echo "later build expected 1.2.3, got ${ver}" >&2
        exit 1
    fi
fi
mkdir -p dist
name="tailscale-${arch}-${ver}-7001002003-srm1.3.spk"
: >"dist/${name}"
printf '%s\n' "dist/${name}" >dist/latest-spk-path
EOF
cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
echo called >>"${GH_CALLED:?}"
exit 99
EOF
chmod +x "$tmp/bin/gh"

out=$(
    PATH="$tmp/bin:$PATH" \
        BUILD_LOG="$tmp/build-log" \
        GH_CALLED="$tmp/gh-called" \
        RELEASE_DRY_RUN=1 \
        sh "$tmp/scripts/release.sh" 9.9.9
)
expected=$(
    n=0
    while read -r arch model; do
        [ -n "$arch" ] || continue
        n=$((n + 1))
        if [ "$n" -eq 1 ]; then
            printf '%s 9.9.9\n' "$arch"
        else
            printf '%s 1.2.3\n' "$arch"
        fi
    done < srm/targets
)
got=$(cat "$tmp/build-log")
if [ "$got" != "$expected" ]; then
    printf 'build invocations:\n%s\n' "$got" >&2
    fail "later builds did not use the version resolved by the first"
fi
if [ -s "$tmp/gh-called" ]; then
    fail "dry run invoked gh"
fi
rows=0
while read -r arch model; do
    [ -n "$arch" ] || continue
    rows=$((rows + 1))
    path="dist/tailscale-${arch}-1.2.3-7001002003-srm1.3.spk"
    case "$out" in
        *"$path"*) ;;
        *) fail "dry run omitted the ${model} package" ;;
    esac
    bullet="- ${model}: $(basename "$path") (${arch})"
    case "$out" in
        *"$bullet"*) ;;
        *) fail "release notes omitted the ${model} target" ;;
    esac
done < srm/targets
asset_count=0
in_assets=0
printf '%s\n' "$out" >"$tmp/dry-text"
while read -r line; do
    if [ "$in_assets" -eq 0 ]; then
        if [ "$line" = "Assets:" ]; then
            in_assets=1
        fi
        continue
    fi
    if [ -z "$line" ]; then
        break
    fi
    case "$line" in
        dist/*) asset_count=$((asset_count + 1)) ;;
    esac
done <"$tmp/dry-text"
if [ "$asset_count" -ne "$rows" ]; then
    fail "dry run printed ${asset_count} assets for ${rows} targets"
fi
case "$out" in
    *'http://<router>:8000/webman/3rdparty/Tailscale/index.cgi/'*) ;;
    *) fail "release notes omitted the admin URL" ;;
esac
case "$out" in
    *USB*) ;;
    *) fail "release notes omitted the WRX560 storage warning" ;;
esac
case "$out" in
    *'were tested'*) fail "release notes still stamp a one-time device test" ;;
esac
case "$out" in
    *1.104.7*) fail "release notes still name the tested Tailscale version" ;;
esac

install=$(sed -n '/^## Install$/,/^## /p' README.md)
hawkeye_spk='tailscale-hawkeye-<version>-srm1.3.spk'
case "$install" in
    *"download \`${hawkeye_spk}\` from the Releases page"*) ;;
    *) fail "install docs do not point WRX560 at the release asset" ;;
esac
case "$install" in
    *'There is no volume'*) ;;
    *) fail "install docs omit the missing-volume failure" ;;
esac

limits=$(sed -n '/^## Limitations$/,/^### /p' README.md)
case "$limits" in
    *'There is no volume'*) ;;
    *) fail "limitations list omits the missing-volume failure" ;;
esac
if ! grep -F '# Tailscale for Synology SRM' README.md >/dev/null; then
    fail "README title is not Tailscale for Synology SRM"
fi
if ! grep -F 'Package Center on the RT2600ac and the WRX560 rejects them' README.md >/dev/null; then
    fail "official-SPK section still names only the RT2600ac"
fi
if ! grep -F 'Build both SRM packages and attach them to a GitHub release' README.md >/dev/null; then
    fail "task table still describes a single release asset"
fi
if ! grep -F 'Build both SRM packages and attach them to a GitHub release' mise.toml >/dev/null; then
    fail "mise release task still describes a single package"
fi
if ! grep -F 'test/srm-targets.sh' mise.toml >/dev/null; then
    fail "mise does not run test/srm-targets.sh"
fi

if grep -F 'mise run ci' .github/workflows/ci.yml >/dev/null; then
    fail "CI still runs lint and test once per architecture"
fi
if ! grep -F 'mise run lint' .github/workflows/ci.yml >/dev/null; then
    fail "CI does not lint once"
fi
if ! grep -F 'mise run test' .github/workflows/ci.yml >/dev/null; then
    fail "CI does not test once"
fi
if ! grep -F 'mise run build' .github/workflows/ci.yml >/dev/null; then
    fail "CI does not build each architecture"
fi
if grep -F 'ipq806x' .github/workflows/ci.yml >/dev/null \
    || grep -F 'hawkeye' .github/workflows/ci.yml >/dev/null; then
    fail "CI matrix still names target arches"
fi
if ! grep -F 'srm/targets' .github/workflows/ci.yml >/dev/null; then
    fail "CI matrix is not computed from srm/targets"
fi
if ! grep -F 'fromJSON' .github/workflows/ci.yml >/dev/null; then
    fail "CI build matrix does not use fromJSON"
fi
if ! grep -F 'needs:' .github/workflows/ci.yml >/dev/null; then
    fail "CI build job does not need the target list"
fi

fork=$(sed -n '/^## Adding another SRM router$/,/^## /p' README.md)
if [ -z "$fork" ]; then
    fail "README has no section for adding another SRM router"
fi
for needle in \
    'srm/targets' \
    'build-srm-spk.sh' \
    'scripts/release.sh' \
    '.github/workflows/ci.yml' \
    'armv7'
do
    case "$fork" in
        *"$needle"*) ;;
        *) fail "fork guide stopped naming ${needle}" ;;
    esac
done

echo "srm targets ok"
