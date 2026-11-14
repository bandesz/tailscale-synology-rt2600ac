#!/bin/sh
# Service start advertises the router's LAN subnets. Tailscale's admin page
# on SRM cannot set routes, and nothing is advertised until something asks.
set -eu

cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/var"
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
export ROUTE_TABLE="$tmp/routes"
: > "$TAILSCALE_LOG"
: > "$SYNOPKG_TEMP_LOGFILE"

# shellcheck source=srm/start-stop-status
. ./srm/start-stop-status

# Little-endian hex, as /proc/net/route prints it.
# 192.168.1.0/24 lbr0, 192.168.2.0/24 gbr0, 10.20.0.0/16 br-iot are LAN.
# eth0 is the default route, so its connected routes are WAN.
# tailscale0, lo, docker0, a /32, a down route, a gateway route, and a
# non-contiguous mask are not LAN subnets.
cat > "$ROUTE_TABLE" << 'EOF'
Iface	Destination	Gateway 	Flags	RefCnt	Use	Metric	Mask		MTU	Window	IRTT
eth0	00000000	0100A8C0	0003	0	0	0	00000000	0	0	0
eth0	0000A8C0	00000000	0001	0	0	0	0000FFFF	0	0	0
eth0	007100CB	00000000	0001	0	0	0	00FFFFFF	0	0	0
lbr0	0001A8C0	00000000	0001	0	0	0	00FFFFFF	0	0	0
gbr0	0002A8C0	00000000	0001	0	0	0	00FFFFFF	0	0	0
br-iot	0000140A	00000000	0001	0	0	0	0000FFFF	0	0	0
lbr0	0000000A	0101A8C0	0003	0	0	0	000000FF	0	0	0
lbr0	3201A8C0	00000000	0001	0	0	0	FFFFFFFF	0	0	0
lbr0	0003A8C0	00000000	0002	0	0	0	00FFFFFF	0	0	0
lbr0	0004A8C0	00000000	0001	0	0	0	00FF00FF	0	0	0
tailscale0	00004064	00000000	0001	0	0	0	0000C0FF	0	0	0
lo	0000007F	00000000	0001	0	0	0	000000FF	0	0	0
docker0	000011AC	00000000	0001	0	0	0	0000FFFF	0	0	0
EOF

want_lan="10.20.0.0/16,192.168.1.0/24,192.168.2.0/24"

got=$(lan_routes_from_proc "$ROUTE_TABLE")
if [ "$got" != "$want_lan" ]; then
    echo "detected routes: expected ${want_lan}" >&2
    echo "got: ${got}" >&2
    exit 1
fi

# Captured from an RT2600ac. eth0's default gateway is 192.168.1.1, so that
# interface is the WAN. The LANs are lbr0, lbr3, and the guest bridge.
cat > "$tmp/router-routes" << 'EOF'
Iface	Destination	Gateway 	Flags	RefCnt	Use	Metric	Mask		MTU	Window	IRTT
eth0	00000000	0101A8C0	0003	0	0	0	00000000	0	0	0
lbr0	0004000A	00000000	0001	0	0	0	00FEFFFF	0	0	0
eth0	E60D7C40	0101A8C0	0007	0	0	0	FFFFFFFF	0	0	0
eth0	0001A8C0	00000000	0001	0	0	0	00FFFFFF	0	0	0
eth0	0101A8C0	0101A8C0	0007	0	0	0	FFFFFFFF	0	0	0
eth0	0101A8C0	00000000	0005	0	0	0	FFFFFFFF	0	0	0
lbr3	0002A8C0	00000000	0001	0	0	0	00FEFFFF	0	0	0
gbr0	0004A8C0	00000000	0001	0	0	0	00FFFFFF	0	0	0
lbr0	000000EF	00000000	0001	0	0	0	000000FF	0	0	0
EOF
want_router="10.0.4.0/23,192.168.2.0/23,192.168.4.0/24"
got=$(lan_routes_from_proc "$tmp/router-routes")
if [ "$got" != "$want_router" ]; then
    echo "router routes: expected ${want_router}" >&2
    echo "got: ${got}" >&2
    exit 1
fi

: > "$TAILSCALE_LOG"
: > "$SYNOPKG_TEMP_LOGFILE"
advertise_routes
want_set="--socket=${SYNOPKG_PKGVAR}/tailscaled.sock set --advertise-routes=${want_lan}"
if ! grep -F -x -e "$want_set" "$TAILSCALE_LOG" >/dev/null; then
    echo "expected: $want_set" >&2
    echo "got:" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi
if [ -s "$SYNOPKG_TEMP_LOGFILE" ]; then
    echo "advertising detected routes wrote a Package Center message:" >&2
    cat "$SYNOPKG_TEMP_LOGFILE" >&2
    exit 1
fi

printf '%s\n' '172.16.0.0/12, 10.1.0.0/16' > "${SYNOPKG_PKGVAR}/advertise-routes"
: > "$TAILSCALE_LOG"
advertise_routes
want_set="--socket=${SYNOPKG_PKGVAR}/tailscaled.sock set --advertise-routes=172.16.0.0/12,10.1.0.0/16"
if ! grep -F -x -e "$want_set" "$TAILSCALE_LOG" >/dev/null; then
    echo "expected override: $want_set" >&2
    echo "got:" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi

: > "${SYNOPKG_PKGVAR}/advertise-routes"
: > "$TAILSCALE_LOG"
advertise_routes
want_set="--socket=${SYNOPKG_PKGVAR}/tailscaled.sock set --advertise-routes="
if ! grep -F -x -e "$want_set" "$TAILSCALE_LOG" >/dev/null; then
    echo "expected an empty override to clear routes" >&2
    echo "got:" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi

rm -f "${SYNOPKG_PKGVAR}/advertise-routes"
: > "$ROUTE_TABLE"
printf '%s\n' "Iface	Destination	Gateway 	Flags	RefCnt	Use	Metric	Mask" >> "$ROUTE_TABLE"
: > "$TAILSCALE_LOG"
advertise_routes
if [ -s "$TAILSCALE_LOG" ]; then
    echo "no detected routes should leave existing advertisements alone" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi

export TAILSCALE_EXIT=1
cat > "$ROUTE_TABLE" << 'EOF'
Iface	Destination	Gateway 	Flags	RefCnt	Use	Metric	Mask
lbr0	0001A8C0	00000000	0001	0	0	0	00FFFFFF
EOF
: > "$TAILSCALE_LOG"
: > "$SYNOPKG_TEMP_LOGFILE"
if ! advertise_routes; then
    echo "a failed route update failed service start" >&2
    exit 1
fi
if ! grep -F -x -e "Could not advertise routes. See ${SYNOPKG_PKGVAR}/tailscaled.stdout.log." "$SYNOPKG_TEMP_LOGFILE" >/dev/null; then
    echo "expected a note that routes were not advertised" >&2
    cat "$SYNOPKG_TEMP_LOGFILE" >&2
    exit 1
fi
unset TAILSCALE_EXIT

printf '0\n' > "$tmp/ip_forward"
enable_ip_forward "$tmp/ip_forward"
if [ "$(cat "$tmp/ip_forward")" != "1" ]; then
    echo "expected IPv4 forwarding to be turned on" >&2
    cat "$tmp/ip_forward" >&2
    exit 1
fi

publish_ui() { :; }
start_daemon() { :; }
expose_socket() { :; }
grant_operator() { :; }
disable_dns() { :; }
pids() { printf '99\n'; }
export TAILSCALE_EXIT=0
: > "$TAILSCALE_LOG"
: > "$SYNOPKG_TEMP_LOGFILE"
# Restore the full table. The override file is gone, so start detects LAN.
cat > "$ROUTE_TABLE" << 'EOF'
Iface	Destination	Gateway 	Flags	RefCnt	Use	Metric	Mask
eth0	00000000	0100A8C0	0003	0	0	0	00000000
lbr0	0001A8C0	00000000	0001	0	0	0	00FFFFFF
gbr0	0002A8C0	00000000	0001	0	0	0	00FFFFFF
br-iot	0000140A	00000000	0001	0	0	0	0000FFFF
EOF
main start
want_set="--socket=${SYNOPKG_PKGVAR}/tailscaled.sock set --advertise-routes=${want_lan}"
if ! grep -F -x -e "$want_set" "$TAILSCALE_LOG" >/dev/null; then
    echo "service start did not advertise detected routes" >&2
    echo "got:" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi

# Login finishes after start. Keep trying until status succeeds, then advertise.
cat > "$tmp/bin/tailscale" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${TAILSCALE_LOG}"
case "$*" in
*" status")
    count=$(cat "${STATUS_COUNT}")
    count=$((count + 1))
    printf '%s\n' "$count" > "${STATUS_COUNT}"
    if [ "$count" -lt 3 ]; then
        exit 1
    fi
    exit 0
    ;;
esac
exit 0
EOF
export STATUS_COUNT="$tmp/status-count"
printf '0\n' > "$STATUS_COUNT"
export ADVERTISE_ATTEMPTS=5
export ADVERTISE_INTERVAL=0
export ROUTE_TABLE="$tmp/router-routes"
: > "$TAILSCALE_LOG"
main advertise-routes
want_set="--socket=${SYNOPKG_PKGVAR}/tailscaled.sock set --advertise-routes=${want_router}"
if ! grep -F -x -e "$want_set" "$TAILSCALE_LOG" >/dev/null; then
    echo "did not advertise after Tailscale came up" >&2
    echo "got:" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi

echo "lan routes advertised on start"
