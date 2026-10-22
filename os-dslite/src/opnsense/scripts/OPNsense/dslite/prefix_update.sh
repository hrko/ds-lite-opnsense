#!/bin/sh

# DS-Lite Fixed IP periodic prefix update.
#
# Refreshes the provider-side registration of our tunnel-local IPv6 address so
# it does not lapse between reconfigurations. Registered as a cron job by
# dslite_cron() in plugins.inc.d/dslite.inc and reachable through the configd
# action "dslite prefix_update".
#
# Shipped as a real file in the package: nothing generates it at runtime, so
# pkg owns it and removes it on uninstall.

SCRIPT_DIR=$(dirname "$0")
if [ -z "${DSLITE_CONFIGURE_LOCKED}" ] && [ -x /usr/bin/lockf ]; then
    DSLITE_CONFIGURE_LOCKED=1
    export DSLITE_CONFIGURE_LOCKED
    exec /usr/bin/lockf -k -t 120 /var/run/dslite_configure.lock "$0" "$@"
fi

. "${SCRIPT_DIR}/lib.sh"

get_config

if [ "${DSLITE_ENABLED}" != "1" ]; then
    exit 0
fi

if [ "$(get_mode)" != "fixedip" ]; then
    exit 0
fi

if [ "${ISP_PROFILE}" = "xpass" ]; then
    WAN_IF=$(get_wan_if_device)
    CE_ADDR=$(python3 "${SCRIPT_DIR}/xpass.py" source "${WAN_IF}") || exit 1
    OWNED_CE=$(awk '{print $2}' "${STATE_OWNED_IF}" 2>/dev/null)
    if [ "${CE_ADDR}" != "${OWNED_CE}" ]; then
        # Registration and tunnel source must change together under the same lock.
        exec "${SCRIPT_DIR}/configure.sh" start
    fi
    # Refresh even unchanged addresses; provider registration can expire.
    exec python3 "${SCRIPT_DIR}/xpass.py" update "${WAN_IF}" --source "${CE_ADDR}"
fi

UPDATE_URL=$(config_get "//OPNsense/dslite/fixedip_update_url")
AUTH_USER=$(config_get "//OPNsense/dslite/fixedip_auth_user")
AUTH_PASS=$(config_get "//OPNsense/dslite/fixedip_auth_pass")

if [ -z "${UPDATE_URL}" ] || [ -z "${AUTH_USER}" ]; then
    exit 0
fi

# Bind the refresh to the CE address: transix registers whatever source address
# the request arrives from, so an unbound request can register the wrong one.
CE_ADDR=$(fixedip_local_v6 "$(config_get "//OPNsense/dslite/fixedip_interface_id")")

# No-op when the CE is unchanged, which is the overwhelmingly common case for a
# job that runs every 30 minutes.
fixedip_register_if_changed "${UPDATE_URL}" "${AUTH_USER}" "${AUTH_PASS}" \
    "${FIXEDIP_ALLOW_INSECURE}" "${CE_ADDR}"

exit 0
