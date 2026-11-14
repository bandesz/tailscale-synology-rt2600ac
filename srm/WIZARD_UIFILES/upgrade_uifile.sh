#!/bin/sh
# Package Center runs this before an upgrade and shows whatever JSON it
# writes to SYNOPKG_TEMP_LOGFILE. The saved answers are the defaults, so
# clicking through does not turn a cleared offer back on. Only this file
# is available while the wizard runs, so it cannot source the other scripts.
set -eu

pkg_name="${SYNOPKG_PKGNAME:-Tailscale}"
pkg_var="${SYNOPKG_PKGVAR:-/var/packages/${pkg_name}/var}"
etc_dir="${STATE_BACKUP_DIR:-/usr/syno/etc/packages/${pkg_name}}"

offer_default() {
    name=$1
    for dir in "${pkg_var}" "${etc_dir}"; do
        file="${dir}/${name}"
        if [ -f "${file}" ]; then
            # Same reader as offer_choice. BusyBox tr would corrupt "false".
            value=""
            IFS= read -r value < "${file}" || true
            cr=$(printf '\r')
            case "${value}" in
            *"${cr}") value=${value%"${cr}"} ;;
            esac
            case "${value}" in
            false) printf 'false\n' ;;
            *) printf 'true\n' ;;
            esac
            return 0
        fi
    done
    printf 'true\n'
}

lan=$(offer_default advertise-lan)
exit_node=$(offer_default advertise-exit-node)

cat > "${SYNOPKG_TEMP_LOGFILE:?}" << EOF
[{
    "step_title": "Tailscale routing",
    "items": [{
        "type": "multiselect",
        "desc": "Choose what this router offers to your tailnet. A tailnet admin still has to approve the choice in the Tailscale admin console before another device can use it.",
        "subitems": [{
            "key": "wizard_advertise_routes",
            "desc": "Advertise LAN subnets",
            "defaultValue": ${lan}
        }, {
            "key": "wizard_advertise_exit_node",
            "desc": "Advertise as an exit node",
            "defaultValue": ${exit_node}
        }]
    }]
}]
EOF
