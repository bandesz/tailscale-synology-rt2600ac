#!/bin/sh
# Install and upgrade ask whether to advertise LAN subnets and an exit node.
# Service start applies the saved answers. A missing answer stays on.
set -eu

cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/var" "$tmp/etc" "$tmp/upgrade"
cat > "$tmp/bin/tailscale" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${TAILSCALE_LOG}"
exit "${TAILSCALE_EXIT:-0}"
EOF
chmod +x "$tmp/bin/tailscale"

export SYNOPKG_PKGDEST="$tmp"
export SYNOPKG_PKGVAR="$tmp/var"
export SYNOPKG_PKGNAME=Tailscale
export SYNOPKG_TEMP_LOGFILE="$tmp/notes"
export TAILSCALE_LOG="$tmp/args"
export STATE_BACKUP_DIR="$tmp/etc"
export SYNOPKG_TEMP_UPGRADE_FOLDER="$tmp/upgrade"
export ROUTE_TABLE="$tmp/routes"
: > "$TAILSCALE_LOG"
: > "$SYNOPKG_TEMP_LOGFILE"

# shellcheck source=srm/start-stop-status
. ./srm/start-stop-status

cat > "$ROUTE_TABLE" << 'EOF'
Iface	Destination	Gateway 	Flags	RefCnt	Use	Metric	Mask		MTU	Window	IRTT
eth0	00000000	0100A8C0	0003	0	0	0	00000000	0	0	0
lbr0	0001A8C0	00000000	0001	0	0	0	00FFFFFF	0	0	0
EOF

want_lan="192.168.1.0/24"
socket="--socket=${SYNOPKG_PKGVAR}/tailscaled.sock"

expect_wizard() {
    file=$1
    want=$2
    if ! python3 - "$file" "$want" << 'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
    items = data[0]["items"][0]["subitems"]
except (OSError, IndexError, KeyError, TypeError, json.JSONDecodeError):
    sys.stderr.write("wizard JSON has no choices: %s\n" % path)
    sys.exit(1)
got = {}
for item in items:
    val = item.get("defaultValue")
    if val is True:
        got[item["key"]] = "true"
    elif val is False:
        got[item["key"]] = "false"
    else:
        got[item["key"]] = "other"
expected = {}
for pair in want.split(","):
    key, value = pair.split("=")
    expected[key] = value
if got != expected:
    sys.stderr.write("expected %s\ngot %s\n" % (expected, got))
    sys.exit(1)
PY
    then
        echo "wizard defaults mismatch for ${file}" >&2
        exit 1
    fi
}

both_on="wizard_advertise_routes=true,wizard_advertise_exit_node=true"
expect_wizard srm/WIZARD_UIFILES/install_uifile "$both_on"

export SYNOPKG_TEMP_LOGFILE="$tmp/upgrade.json"
sh ./srm/WIZARD_UIFILES/upgrade_uifile.sh
expect_wizard "$SYNOPKG_TEMP_LOGFILE" "$both_on"

printf '%s\n' false > "${SYNOPKG_PKGVAR}/advertise-exit-node"
sh ./srm/WIZARD_UIFILES/upgrade_uifile.sh
expect_wizard "$SYNOPKG_TEMP_LOGFILE" "wizard_advertise_routes=true,wizard_advertise_exit_node=false"

rm -f "${SYNOPKG_PKGVAR}/advertise-exit-node"
printf '%s\n' false > "${STATE_BACKUP_DIR}/advertise-lan"
sh ./srm/WIZARD_UIFILES/upgrade_uifile.sh
expect_wizard "$SYNOPKG_TEMP_LOGFILE" "wizard_advertise_routes=false,wizard_advertise_exit_node=true"
rm -f "${STATE_BACKUP_DIR}/advertise-lan"

export SYNOPKG_TEMP_LOGFILE="$tmp/notes"

unset wizard_advertise_routes wizard_advertise_exit_node || true
save_offers
if [ -e "${SYNOPKG_PKGVAR}/advertise-lan" ] || [ -e "${SYNOPKG_PKGVAR}/advertise-exit-node" ]; then
    echo "a skipped wizard page wrote offer files" >&2
    exit 1
fi

export wizard_advertise_routes=true
unset wizard_advertise_exit_node || true
save_offers
if [ "$(cat "${SYNOPKG_PKGVAR}/advertise-lan")" != "true" ]; then
    echo "LAN checkbox was not saved" >&2
    exit 1
fi
if [ "$(cat "${SYNOPKG_PKGVAR}/advertise-exit-node")" != "false" ]; then
    echo "an omitted exit-node checkbox was saved as on" >&2
    exit 1
fi

export wizard_advertise_routes=false
export wizard_advertise_exit_node=true
save_offers
if [ "$(cat "${SYNOPKG_PKGVAR}/advertise-lan")" != "false" ] || [ "$(cat "${SYNOPKG_PKGVAR}/advertise-exit-node")" != "true" ]; then
    echo "wizard answers were not saved: $(ls "${SYNOPKG_PKGVAR}")" >&2
    exit 1
fi

: > "$TAILSCALE_LOG"
advertise_routes
advertise_exit_node
if ! grep -F -x -e "${socket} set --advertise-routes=" "$TAILSCALE_LOG" >/dev/null; then
    echo "clearing LAN advertisement still offered routes" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi
if ! grep -F -x -e "${socket} set --advertise-exit-node=true" "$TAILSCALE_LOG" >/dev/null; then
    echo "exit node was not advertised" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi

printf '%s\n' '10.1.0.0/16' > "${SYNOPKG_PKGVAR}/advertise-routes"
: > "$TAILSCALE_LOG"
advertise_routes
if ! grep -F -x -e "${socket} set --advertise-routes=" "$TAILSCALE_LOG" >/dev/null; then
    echo "a prefix file overrode a cleared LAN checkbox" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi
rm -f "${SYNOPKG_PKGVAR}/advertise-routes"

printf '%s\n' true > "${SYNOPKG_PKGVAR}/advertise-lan"
printf '%s\n' false > "${SYNOPKG_PKGVAR}/advertise-exit-node"
: > "$TAILSCALE_LOG"
advertise_routes
advertise_exit_node
if ! grep -F -x -e "${socket} set --advertise-routes=${want_lan}" "$TAILSCALE_LOG" >/dev/null; then
    echo "LAN advertisement did not offer the detected subnet" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi
if ! grep -F -x -e "${socket} set --advertise-exit-node=false" "$TAILSCALE_LOG" >/dev/null; then
    echo "exit node stayed advertised after it was turned off" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi

rm -f "${SYNOPKG_PKGVAR}/advertise-lan" "${SYNOPKG_PKGVAR}/advertise-exit-node"
: > "$TAILSCALE_LOG"
advertise_exit_node
if ! grep -F -x -e "${socket} set --advertise-exit-node=true" "$TAILSCALE_LOG" >/dev/null; then
    echo "a missing exit-node answer did not stay on" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi

export TAILSCALE_EXIT=1
: > "$SYNOPKG_TEMP_LOGFILE"
if ! advertise_exit_node; then
    echo "a failed exit-node update failed service start" >&2
    exit 1
fi
if ! grep -F -x -e "Could not advertise the exit node. See ${SYNOPKG_PKGVAR}/tailscaled.stdout.log." "$SYNOPKG_TEMP_LOGFILE" >/dev/null; then
    echo "expected a note that the exit node was not advertised" >&2
    cat "$SYNOPKG_TEMP_LOGFILE" >&2
    exit 1
fi
unset TAILSCALE_EXIT

printf '%s\n' false > "${SYNOPKG_PKGVAR}/advertise-lan"
printf '%s\n' false > "${SYNOPKG_PKGVAR}/advertise-exit-node"
sh ./srm/preupgrade
rm -f "${SYNOPKG_PKGVAR}/advertise-lan" "${SYNOPKG_PKGVAR}/advertise-exit-node"
unset wizard_advertise_routes wizard_advertise_exit_node || true
sh ./srm/postupgrade
if [ "$(cat "${SYNOPKG_PKGVAR}/advertise-lan")" != "false" ] || [ "$(cat "${SYNOPKG_PKGVAR}/advertise-exit-node")" != "false" ]; then
    echo "upgrade dropped a saved routing choice" >&2
    exit 1
fi

rm -f "${SYNOPKG_PKGVAR}/advertise-lan" "${SYNOPKG_PKGVAR}/advertise-exit-node"
export wizard_advertise_routes=true
export wizard_advertise_exit_node=false
sh ./srm/postupgrade
if [ "$(cat "${SYNOPKG_PKGVAR}/advertise-lan")" != "true" ] || [ "$(cat "${SYNOPKG_PKGVAR}/advertise-exit-node")" != "false" ]; then
    echo "upgrade wizard did not replace the saved choices" >&2
    exit 1
fi

export wizard_advertise_routes=true
export wizard_advertise_exit_node=true
sh ./srm/postinst
if [ "$(cat "${SYNOPKG_PKGVAR}/advertise-lan")" != "true" ] || [ "$(cat "${SYNOPKG_PKGVAR}/advertise-exit-node")" != "true" ]; then
    echo "installation did not keep the wizard answers" >&2
    exit 1
fi

publish_ui() { :; }
start_daemon() { :; }
expose_socket() { :; }
grant_operator() { :; }
disable_dns() { :; }
enable_ip_forward() { :; }
pids() { printf '99\n'; }
rm -f "${SYNOPKG_PKGVAR}/advertise-lan" "${SYNOPKG_PKGVAR}/advertise-exit-node" \
    "${SYNOPKG_PKGVAR}/advertise-routes" \
    "${STATE_BACKUP_DIR}/advertise-lan" "${STATE_BACKUP_DIR}/advertise-exit-node" \
    "${SYNOPKG_TEMP_UPGRADE_FOLDER}/advertise-lan" "${SYNOPKG_TEMP_UPGRADE_FOLDER}/advertise-exit-node"
: > "$TAILSCALE_LOG"
main start
if ! grep -F -x -e "${socket} set --advertise-routes=${want_lan}" "$TAILSCALE_LOG" >/dev/null; then
    echo "service start did not advertise the LAN" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi
if ! grep -F -x -e "${socket} set --advertise-exit-node=true" "$TAILSCALE_LOG" >/dev/null; then
    echo "service start did not advertise the exit node" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi

printf '%s\n' false > "${SYNOPKG_PKGVAR}/advertise-lan"
printf '%s\n' false > "${SYNOPKG_PKGVAR}/advertise-exit-node"
: > "$TAILSCALE_LOG"
main start
if ! grep -F -x -e "${socket} set --advertise-routes=" "$TAILSCALE_LOG" >/dev/null; then
    echo "service start offered LAN routes that were turned off" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi
if ! grep -F -x -e "${socket} set --advertise-exit-node=false" "$TAILSCALE_LOG" >/dev/null; then
    echo "service start left the exit node on after it was turned off" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi

# shellcheck source=build-srm-spk.sh
. ./build-srm-spk.sh
stage_wizard "$tmp/stage"
expect_wizard "$tmp/stage/WIZARD_UIFILES/install_uifile" "$both_on"
if [ ! -x "$tmp/stage/WIZARD_UIFILES/upgrade_uifile.sh" ]; then
    echo "upgrade wizard script is not executable" >&2
    exit 1
fi
if ! awk '
    /pack_ustar -cf "\$out"/ { found = 1 }
    found && /WIZARD_UIFILES/ { ok = 1 }
    END { exit !ok }
' build-srm-spk.sh; then
    echo "SPK archive does not include WIZARD_UIFILES" >&2
    exit 1
fi

# SRM's BusyBox tr does not implement POSIX classes. tr -d '[:space:]'
# deletes the characters of that string, so "false" becomes "fl" and was
# read back as on. Stop and start then advertises both offers again.
mkdir -p "$tmp/busybox-bin"
cat > "$tmp/busybox-bin/tr" << 'EOF'
#!/bin/sh
if [ "$1" != "-d" ]; then
    echo "unexpected tr usage: $*" >&2
    exit 1
fi
awk -v drop="$2" '
{
    out = ""
    n = length(drop)
    for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        skip = 0
        for (j = 1; j <= n; j++) {
            if (substr(drop, j, 1) == c) skip = 1
        }
        if (!skip) out = out c
    }
    printf "%s", out
}
'
EOF
chmod +x "$tmp/busybox-bin/tr"
printf '%s\n' false > "${SYNOPKG_PKGVAR}/advertise-lan"
printf '%s\n' false > "${SYNOPKG_PKGVAR}/advertise-exit-node"
got=$(PATH="$tmp/busybox-bin:$PATH" offer_choice "${SYNOPKG_PKGVAR}/advertise-exit-node")
if [ "$got" != "false" ]; then
    echo "BusyBox tr made a false exit-node file look on: ${got}" >&2
    exit 1
fi
got=$(PATH="$tmp/busybox-bin:$PATH" offer_choice "${SYNOPKG_PKGVAR}/advertise-lan")
if [ "$got" != "false" ]; then
    echo "BusyBox tr made a false LAN file look on: ${got}" >&2
    exit 1
fi
export SYNOPKG_TEMP_LOGFILE="$tmp/upgrade-busybox.json"
PATH="$tmp/busybox-bin:$PATH" sh ./srm/WIZARD_UIFILES/upgrade_uifile.sh
expect_wizard "$SYNOPKG_TEMP_LOGFILE" "wizard_advertise_routes=false,wizard_advertise_exit_node=false"

echo "routing offers follow the install choices"
