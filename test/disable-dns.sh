#!/bin/sh
# Service start must turn Tailscale DNS off. AcceptDNS rewrites the router's
# resolver, and this package only runs on a router.
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
: > "$TAILSCALE_LOG"
: > "$SYNOPKG_TEMP_LOGFILE"

# shellcheck source=srm/start-stop-status
. ./srm/start-stop-status

publish_ui() { :; }
start_daemon() { :; }
expose_socket() { :; }

cgi_user() { printf 'http\n'; }
: > "$TAILSCALE_LOG"
: > "$SYNOPKG_TEMP_LOGFILE"
grant_operator
if ! grep -F -x -e "--socket=${SYNOPKG_PKGVAR}/tailscaled.sock set --operator=http" "$TAILSCALE_LOG" >/dev/null; then
    echo "expected operator grant for http" >&2
    cat "$TAILSCALE_LOG" >&2
    exit 1
fi
if [ -s "$SYNOPKG_TEMP_LOGFILE" ]; then
    echo "granting the operator wrote a Package Center message:" >&2
    cat "$SYNOPKG_TEMP_LOGFILE" >&2
    exit 1
fi
grant_operator() { :; }

expect_dns_off() {
    want="--socket=${SYNOPKG_PKGVAR}/tailscaled.sock set --accept-dns=false"
    if ! grep -F -x -e "$want" "$TAILSCALE_LOG" >/dev/null; then
        echo "expected: $want" >&2
        echo "got:" >&2
        cat "$TAILSCALE_LOG" >&2
        exit 1
    fi
}

pids() { printf '99\n'; }
: > "$TAILSCALE_LOG"
: > "$SYNOPKG_TEMP_LOGFILE"
main start
expect_dns_off
if [ -s "$SYNOPKG_TEMP_LOGFILE" ]; then
    echo "a normal start wrote a Package Center message:" >&2
    cat "$SYNOPKG_TEMP_LOGFILE" >&2
    exit 1
fi

pids() { return 0; }
: > "$TAILSCALE_LOG"
main start
expect_dns_off

export TAILSCALE_EXIT=1
: > "$TAILSCALE_LOG"
: > "$SYNOPKG_TEMP_LOGFILE"
if ! main start; then
    echo "start failed when turning DNS off failed" >&2
    exit 1
fi
if ! grep -F -x -e "Could not turn Tailscale DNS off. See ${SYNOPKG_PKGVAR}/tailscaled.stdout.log." "$SYNOPKG_TEMP_LOGFILE" >/dev/null; then
    echo "expected a note that DNS stayed on" >&2
    cat "$SYNOPKG_TEMP_LOGFILE" >&2
    exit 1
fi

echo "accept-dns disabled on start"
