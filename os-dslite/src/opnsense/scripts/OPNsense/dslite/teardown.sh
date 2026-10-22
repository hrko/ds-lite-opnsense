#!/bin/sh

# DS-Lite tunnel teardown script
# Removes the gif tunnel interface and associated configuration.
#
# Every destructive step is gated on proof of ownership. This script runs from
# the configd "stop" action, which is also invoked by the package pre-deinstall
# hook, so it must be a no-op on a box where DS-Lite was never configured -- and
# it must never touch a default route or a gif interface belonging to something
# else.

SCRIPT_DIR=$(dirname "$0")
if [ -z "${DSLITE_CONFIGURE_LOCKED}" ] && [ -x /usr/bin/lockf ]; then
    DSLITE_CONFIGURE_LOCKED=1
    export DSLITE_CONFIGURE_LOCKED
    exec /usr/bin/lockf -k -t 120 /var/run/dslite_configure.lock "$0" "$@"
fi

. "${SCRIPT_DIR}/lib.sh"

get_config

logger -t dslite "Tearing down DS-Lite tunnel"

rc=0

# Remove the default route only when it is still the one we installed.
remove_owned_default_route

# Flush pf anchor rules (harmless when the anchors are already empty).
pfctl -a "dslite/nat" -F all >/dev/null 2>&1
pfctl -a "dslite/fw" -F all >/dev/null 2>&1
pfctl -a "dslite" -F all >/dev/null 2>&1

# Destroy the tunnel interface only when we can prove we created it.
if ! tunnel_exists; then
    logger -t dslite "Tunnel interface ${TUNNEL_IF} not present"
elif tunnel_is_ours "${TUNNEL_IF}"; then
    ifconfig "${TUNNEL_IF}" down 2>/dev/null
    if ifconfig "${TUNNEL_IF}" destroy 2>/dev/null; then
        logger -t dslite "Tunnel interface ${TUNNEL_IF} destroyed"
    else
        logger -t dslite "WARNING: failed to destroy ${TUNNEL_IF}"
        rc=1
    fi
else
    logger -t dslite "Leaving ${TUNNEL_IF} alone: it was not created by this plugin"
fi
rm -f "${STATE_OWNED_IF}"

# Remove the managed WAN /128 tunnel-local alias (Fixed IP mode). The recorded
# device is used in preference to the currently configured one, so a WAN change
# still cleans up the interface that actually carries the alias.
if ! remove_wan_alias "$(get_wan_if_device)"; then
    logger -t dslite "WARNING: managed WAN /128 alias could not be removed; state kept for retry"
    rc=1
fi

# Cleanup temp files
rm -f /tmp/dslite_nat.conf /tmp/dslite_fw.conf /var/run/dslite_health_cache

logger -t dslite "DS-Lite teardown complete"
exit ${rc}
