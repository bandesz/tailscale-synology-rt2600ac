#!/bin/sh
# The menu icon has to be a symlink into the package directory. synohdpack
# rejects a regular file copied under webman/3rdparty. index.cgi has to stay
# a real file so Apache will execute it.
set -eu

cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/pkg/ui" "$tmp/bin" "$tmp/web/3rdparty" "$tmp/var"
printf 'icon-bytes\n' > "$tmp/pkg/ui/PACKAGE_ICON_256.PNG"
printf '{}\n' > "$tmp/pkg/ui/config"
printf '#!/bin/sh\n' > "$tmp/pkg/ui/index.cgi"
# An earlier start copied the icon. Publishing again must replace that file.
mkdir -p "$tmp/web/3rdparty/Tailscale"
printf 'old-icon\n' > "$tmp/web/3rdparty/Tailscale/PACKAGE_ICON_256.PNG"

cat > "$tmp/bin/chown" << 'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/chown"

export PATH="$tmp/bin:$PATH"
export SYNOPKG_PKGDEST="$tmp/pkg"
export SYNOPKG_PKGVAR="$tmp/var"
export SYNOPKG_PKGNAME=Tailscale
export SYNOPKG_TEMP_LOGFILE="$tmp/notes"
export UI_ROOT="$tmp/web/3rdparty"
: > "$SYNOPKG_TEMP_LOGFILE"

# shellcheck source=srm/start-stop-status
. ./srm/start-stop-status

publish_ui

icon="$UI_ROOT/Tailscale/PACKAGE_ICON_256.PNG"
if [ ! -L "$icon" ]; then
    echo "icon is not a symlink" >&2
    ls -la "$UI_ROOT/Tailscale" >&2
    exit 1
fi
if [ "$(readlink "$icon")" != "$tmp/pkg/ui/PACKAGE_ICON_256.PNG" ]; then
    echo "icon symlink target is $(readlink "$icon")" >&2
    exit 1
fi
if [ -L "$UI_ROOT/Tailscale/index.cgi" ]; then
    echo "index.cgi must be a real file" >&2
    exit 1
fi
if ! cmp -s "$tmp/pkg/ui/config" "$UI_ROOT/Tailscale/config"; then
    echo "config was not copied" >&2
    exit 1
fi

echo "menu icon symlinks into the package"
