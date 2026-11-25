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

if SRM_ARCH=nope sh build-srm-spk.sh 1.2.3 >"$tmp/arch-out" 2>"$tmp/arch-err"; then
    fail "accepted unsupported SRM_ARCH"
fi
if ! grep -F 'unsupported SRM_ARCH: nope' "$tmp/arch-err" >/dev/null; then
    fail "unsupported SRM_ARCH did not explain the failure"
fi

got=$(SRM_ARCH=nope sh build-srm-spk.sh --syno-version 1.104.7)
if [ "$got" != 700104007 ]; then
    fail "SRM_ARCH leaked into --syno-version (got ${got})"
fi

if RELEASE_DRY_RUN=2 sh scripts/release.sh 9.9.9 >"$tmp/dry-out" 2>"$tmp/dry-err"; then
    fail "accepted RELEASE_DRY_RUN=2"
fi
if ! grep -F 'RELEASE_DRY_RUN must be 0 or 1' "$tmp/dry-err" >/dev/null; then
    fail "bad RELEASE_DRY_RUN did not explain the failure"
fi

mkdir -p "$tmp/scripts" "$tmp/bin"
cp scripts/release.sh "$tmp/scripts/release.sh"
cat >"$tmp/build-srm-spk.sh" <<'EOF'
#!/bin/sh
set -eu
printf '%s %s\n' "${SRM_ARCH:-unset}" "${1:-}" >>"${BUILD_LOG:?}"
arch=${SRM_ARCH:-ipq806x}
if [ "$arch" = ipq806x ]; then
    ver=1.2.3
else
    ver=${1:?}
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
expected=$(printf '%s\n' 'ipq806x 9.9.9' 'hawkeye 1.2.3')
got=$(cat "$tmp/build-log")
if [ "$got" != "$expected" ]; then
    printf 'build invocations:\n%s\n' "$got" >&2
    fail "second build did not use the version resolved by the first"
fi
if [ -s "$tmp/gh-called" ]; then
    fail "dry run invoked gh"
fi
case "$out" in
    *dist/tailscale-ipq806x-1.2.3-7001002003-srm1.3.spk*) ;;
    *) fail "dry run omitted the RT2600ac package" ;;
esac
case "$out" in
    *dist/tailscale-hawkeye-1.2.3-7001002003-srm1.3.spk*) ;;
    *) fail "dry run omitted the WRX560 package" ;;
esac
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

echo "srm targets ok"
