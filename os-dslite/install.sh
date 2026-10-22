#!/bin/sh

# OPNsense DS-Lite Plugin Installer
# Works over IPv6-only connections (for pre-tunnel install)
# Run this directly on the OPNsense box:
#   curl -6 -sfL -o /tmp/install-dslite.sh "https://raw.githubusercontent.com/hrko/ds-lite-opnsense/main/os-dslite/install.sh" && sh /tmp/install-dslite.sh
#
# Or offline, with no network at all: copy the whole os-dslite directory onto a
# USB stick, mount it on the box, and run install.sh from there. The script uses
# the src/ tree sitting next to it and never reaches for the network.
#   mount -t msdosfs /dev/da0s1 /mnt && sh /mnt/os-dslite/install.sh
#
# Set DSLITE_BUILD_ONLY=1 to build the package and stop without installing it.
# Use that to verify a USB stick on a working box before you rely on it at a
# site with no network.

set -e

# Files are fetched individually from raw.githubusercontent.com rather than as a
# tarball from github.com, because github.com and codeload.github.com are
# IPv4-only -- they publish no AAAA record. raw.githubusercontent.com is behind
# Fastly and does have real IPv6. Since the whole point of this installer is to
# run on a box whose IPv4 does not exist until the tunnel it installs is up,
# pulling the tarball would fail exactly when it is needed most.
BRANCH="${DSLITE_BRANCH:-main}"
REPO_BASE="https://raw.githubusercontent.com/hrko/ds-lite-opnsense/${BRANCH}/os-dslite"
BASE_URL="${REPO_BASE}/src"
TMP_DIR="/tmp/dslite-install"

# Where the sources come from. A src/ tree sitting next to this script is the
# shape you get by copying the whole os-dslite directory onto a USB stick, so
# treat that as an explicit request for an offline install: use those files and
# never touch the network. DSLITE_SRC overrides, for a tree kept elsewhere.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_LOCAL="${DSLITE_SRC:-}"
if [ -z "${SRC_LOCAL}" ] && [ -d "${SCRIPT_DIR}/src/opnsense" ]; then
    SRC_LOCAL="${SCRIPT_DIR}/src"
fi

# Source paths, relative to os-dslite/src. The install destination is always
# /usr/local/<same relative path>, so one list drives both the staged package
# and the degraded file-copy fallback.
FILES="
etc/inc/plugins.inc.d/dslite.inc
opnsense/mvc/app/controllers/OPNsense/DSLite/GeneralController.php
opnsense/mvc/app/controllers/OPNsense/DSLite/DiagnosticsController.php
opnsense/mvc/app/controllers/OPNsense/DSLite/Api/SettingsController.php
opnsense/mvc/app/controllers/OPNsense/DSLite/Api/ServiceController.php
opnsense/mvc/app/controllers/OPNsense/DSLite/forms/general.xml
opnsense/mvc/app/models/OPNsense/DSLite/DSLite.xml
opnsense/mvc/app/models/OPNsense/DSLite/DSLite.php
opnsense/mvc/app/models/OPNsense/DSLite/ACL/ACL.xml
opnsense/mvc/app/models/OPNsense/DSLite/Menu/Menu.xml
opnsense/mvc/app/views/OPNsense/DSLite/general.volt
opnsense/mvc/app/views/OPNsense/DSLite/diagnostics.volt
opnsense/scripts/OPNsense/dslite/lib.sh
opnsense/scripts/OPNsense/dslite/xpass.py
opnsense/scripts/OPNsense/dslite/configure.sh
opnsense/scripts/OPNsense/dslite/teardown.sh
opnsense/scripts/OPNsense/dslite/status.sh
opnsense/scripts/OPNsense/dslite/diagnostics.sh
opnsense/scripts/OPNsense/dslite/prefix_update.sh
opnsense/scripts/OPNsense/dslite/mape_calc.sh
opnsense/service/conf/actions.d/actions_dslite.conf
opnsense/www/js/widgets/DSLite.js
opnsense/www/js/widgets/Metadata/DSLite.xml
"

echo "=== OPNsense DS-Lite Plugin Installer ==="
if [ -n "${SRC_LOCAL}" ]; then
    echo "source: ${SRC_LOCAL} (offline)"
else
    if ! printf '%s' "${BRANCH}" | grep -Eq '^[0-9a-f]{40}$'; then
        echo "ERROR: Set DSLITE_BRANCH to a reviewed 40-character commit SHA, or use offline sources."
        exit 1
    fi
    echo "source: commit ${BRANCH} (network)"
fi
echo ""

# Check we're on OPNsense
if [ ! -f /usr/local/etc/inc/plugins.inc.d/pf.inc ]; then
    echo "ERROR: This script must be run on an OPNsense system."
    exit 1
fi

if command -v curl >/dev/null 2>&1; then
    DL="curl"
elif command -v fetch >/dev/null 2>&1; then
    DL="fetch"
else
    echo "ERROR: No download tool available (curl or fetch required)"
    exit 1
fi

# Fetch one file. Prefers IPv6 but does not force it: forcing -6 breaks the
# install on a dual-stack box whose resolver hands back an IPv4-only CDN node,
# and the earlier version failed silently when that happened.
fetch_one() {
    _src="$1"
    _dst="$2"

    if [ "${DL}" = "curl" ]; then
        curl -6 -sfL --connect-timeout 10 -o "${_dst}" "${_src}" 2>/dev/null && return 0
        curl -sfL --connect-timeout 10 -o "${_dst}" "${_src}" 2>/dev/null && return 0
    else
        fetch -q -o "${_dst}" "${_src}" && return 0
    fi
    return 1
}

# Fetch to ${TMP_DIR}/<rel>, aborting on transport failure or an empty result.
# A 404 from raw returns the string "404: Not Found" with a success status under
# some curl versions; catch that rather than installing a stub file.
fetch_checked() {
    _rel="$1"
    _url="$2"

    mkdir -p "${TMP_DIR}/$(dirname "${_rel}")"
    if ! fetch_one "${_url}" "${TMP_DIR}/${_rel}"; then
        echo ""
        echo "ERROR: failed to download ${_rel}"
        echo "       from ${_url}"
        echo ""
        echo "Check connectivity to raw.githubusercontent.com. Note that"
        echo "github.com itself is IPv4-only, so on an IPv6-only box only the"
        echo "raw.githubusercontent.com host is reachable."
        exit 1
    fi
    if [ ! -s "${TMP_DIR}/${_rel}" ]; then
        echo "ERROR: ${_rel} downloaded empty -- aborting"
        exit 1
    fi
}

# The package builder travels with the sources in both modes. Duplicating its
# manifest and plist logic here is what let the two paths drift apart before:
# the packaged install grew the /usr/local/opnsense/version metadata that makes
# a plugin visible to System > Firmware > Plugins, and this installer did not,
# so a curl-pipe install stayed invisible and was dropped by the next firmware
# upgrade without a trace. One builder, one source of truth.

stage_from_network() {
    echo "Downloading plugin (${BRANCH})..."

    total=$(($(echo "${FILES}" | wc -w | tr -d ' ') + 1))
    count=0
    for rel in ${FILES}; do
        fetch_checked "src/${rel}" "${BASE_URL}/${rel}"
        count=$((count + 1))
        printf '\r  %d/%d files' "${count}" "${total}"
    done

    fetch_checked "tools/build-pkg.sh" "${REPO_BASE}/tools/build-pkg.sh"
    count=$((count + 1))
    printf '\r  %d/%d files\n' "${count}" "${total}"
}

stage_from_local() {
    echo "Staging from ${SRC_LOCAL}..."

    # The builder lives one level up from src/, unless pointed elsewhere.
    BUILDER="${DSLITE_BUILDER:-${SRC_LOCAL%/src}/tools/build-pkg.sh}"

    # Check the whole tree before copying any of it. A half-populated USB stick
    # should fail with a list of what is missing, not with a plugin that is
    # silently short a controller and 500s the moment you open its page.
    missing=""
    for rel in ${FILES}; do
        [ -s "${SRC_LOCAL}/${rel}" ] || missing="${missing} src/${rel}"
    done
    [ -s "${BUILDER}" ] || missing="${missing} tools/build-pkg.sh"

    if [ -n "${missing}" ]; then
        echo ""
        echo "ERROR: the local source tree is incomplete. Missing:"
        for m in ${missing}; do echo "         ${m}"; done
        echo ""
        echo "       Copy the whole os-dslite directory, not just install.sh."
        echo "       Expected layout next to this script:"
        echo "         os-dslite/install.sh"
        echo "         os-dslite/src/..."
        echo "         os-dslite/tools/build-pkg.sh"
        exit 1
    fi

    count=0
    for rel in ${FILES}; do
        mkdir -p "${TMP_DIR}/src/$(dirname "${rel}")"
        cp "${SRC_LOCAL}/${rel}" "${TMP_DIR}/src/${rel}"
        count=$((count + 1))
    done
    mkdir -p "${TMP_DIR}/tools"
    cp "${BUILDER}" "${TMP_DIR}/tools/build-pkg.sh"
    count=$((count + 1))
    echo "  staged ${count} files"
}

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

if [ -n "${SRC_LOCAL}" ]; then
    stage_from_local
else
    stage_from_network
fi

# What lands in product_hash, which is how you tell later which tree a box is
# running. Offline from a git checkout we can name the commit exactly; from a
# plain copy on a USB stick there is nothing to name. Over the network a commit
# SHA is not obtainable at all, because api.github.com publishes no AAAA record
# and is unreachable on the IPv6-only box that path exists for.
if [ -n "${SRC_LOCAL}" ]; then
    BUILD_HASH="offline"
    if command -v git >/dev/null 2>&1; then
        _sha=$(git -C "${SCRIPT_DIR}" rev-parse --short=9 HEAD 2>/dev/null || true)
        [ -n "${_sha}" ] && BUILD_HASH="${_sha}"
    fi
else
    BUILD_HASH="branch-${BRANCH}"
fi

# ---------------------------------------------------------------------------
# Preferred path: build a real FreeBSD package and install it.
# ---------------------------------------------------------------------------
install_as_package() {
    command -v pkg >/dev/null 2>&1 || return 1

    chmod +x "${TMP_DIR}/tools/build-pkg.sh" 2>/dev/null || true

    # build-pkg.sh resolves the hash with git against its own project root, which
    # is the staging directory here and never a checkout, so pass it explicitly
    # rather than letting it fall back to "undefined".
    PKG_HASH="${BUILD_HASH}" \
    OUT_DIR="${TMP_DIR}/dist" \
    WORK_DIR="${TMP_DIR}/.pkgbuild" \
        sh "${TMP_DIR}/tools/build-pkg.sh" >"${TMP_DIR}/build.log" 2>&1 || {
        echo "  package build failed:"
        sed 's/^/    /' "${TMP_DIR}/build.log" | tail -15
        return 1
    }

    _pkgfile=$(find "${TMP_DIR}/dist" -name 'os-dslite-*.pkg' -o -name 'os-dslite-*.txz' 2>/dev/null | head -1)
    if [ -z "${_pkgfile}" ]; then
        echo "  package build produced no output"
        return 1
    fi

    echo "  built $(basename "${_pkgfile}")"

    # Stop before touching the running system. pkg add's pre-deinstall stops the
    # tunnel, so this is also the only way to exercise the whole path on a box
    # whose WAN is currently riding on it.
    if [ -n "${DSLITE_BUILD_ONLY:-}" ]; then
        _out="${DSLITE_OUT_DIR:-/tmp}"
        mkdir -p "${_out}"
        cp "${_pkgfile}" "${_out}/"
        echo ""
        echo "=== Build only: package written, nothing installed ==="
        echo "  ${_out}/$(basename "${_pkgfile}")"
        echo ""
        echo "Install it with:"
        echo "  pkg add -f ${_out}/$(basename "${_pkgfile}")"
        rm -rf "${TMP_DIR}"
        exit 0
    fi

    # -f so a reinstall of the same version replaces rather than no-ops.
    if ! pkg add -f "${_pkgfile}" >"${TMP_DIR}/pkgadd.log" 2>&1; then
        echo "  pkg add failed:"
        sed 's/^/    /' "${TMP_DIR}/pkgadd.log" | tail -15
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Fallback: copy files into place. Used only when the package path fails, so
# that a box with no working IPv4 can still get its tunnel up. This leaves the
# plugin unregistered with pkg, which is why it warns loudly at the end.
# ---------------------------------------------------------------------------
install_as_files() {
    for rel in ${FILES}; do
        dst="/usr/local/${rel}"
        mkdir -p "$(dirname "${dst}")"
        cp "${TMP_DIR}/src/${rel}" "${dst}"
    done
    chmod +x /usr/local/opnsense/scripts/OPNsense/dslite/*.sh

    # Write the plugin metadata by hand. OPNsense does not discover plugins from
    # the package database: firmware/register.php globs
    # /usr/local/opnsense/version/* and parses each file as JSON, keying on
    # product_id. Without this the plugin is invisible in the GUI. It still
    # cannot be reinstalled automatically after a firmware upgrade, because no
    # repository carries the package -- but at least it is visible enough to
    # notice, rather than disappearing silently.
    _abi=$(sed -n 's/.*"product_abi": *"\([^"]*\)".*/\1/p' \
        /usr/local/opnsense/version/core 2>/dev/null | head -1)
    [ -n "${_abi}" ] || _abi="unknown"

    mkdir -p /usr/local/opnsense/version
    cat > /usr/local/opnsense/version/dslite <<VERSION
{
    "product_abi": "${_abi}",
    "product_arch": "$(uname -m)",
    "product_conflicts": "os-dslite-devel",
    "product_email": "kawaii-not-kawaii@users.noreply.github.com",
    "product_hash": "${BUILD_HASH}",
    "product_id": "os-dslite",
    "product_name": "dslite",
    "product_tier": "4",
    "product_version": "$(date +%Y.%m.%d.%H%M)",
    "product_website": "https://github.com/hrko/ds-lite-opnsense"
}
VERSION
}

echo "Installing plugin..."
PACKAGED=1
if ! install_as_package; then
    echo ""
    echo "  falling back to a file copy"
    install_as_files
    PACKAGED=0
fi

# Restart configd so the new actions_dslite.conf is read. The package
# post-install already does this, but the fallback path has no hooks.
if [ "${PACKAGED}" -eq 0 ]; then
    echo "Restarting configd..."
    service configd restart
fi

# Flush caches
rm -rf /tmp/opnsense_*cache* 2>/dev/null

# Re-register cron. Neither a file copy nor pkg's post-install rebuilds the
# crontab from dslite_cron() -- only a config write does. Without this the
# */30 prefix-update job never runs, and on a Fixed IP service that means the CE
# registration goes stale the next time the delegated prefix changes, silently.
echo "Re-registering cron jobs..."
configctl cron restart >/dev/null 2>&1 || true

# Register the tunnel interface. dslite_interfaces() runs only from
# plugins_interfaces(), which fires on a config write -- so after a fresh
# install the tunnel can come up with no <dslite> entry under <interfaces>,
# meaning nothing appears in the GUI interface list and no gateway can be
# attached to it. pluginctl -i performs that registration without waiting for
# the user to click Save.
echo "Registering plugin interfaces..."
pluginctl -i >/dev/null 2>&1 || true

# Cleanup
rm -rf "${TMP_DIR}"

echo ""
echo "=== Installation complete! ==="
echo ""

if [ "${PACKAGED}" -eq 1 ]; then
    pkg info os-dslite 2>/dev/null | sed -n '1,2p' | sed 's/^/  /'
else
    echo "  WARNING: installed by file copy, not as a package."
    echo ""
    echo "  pkg has no record of these files, so a firmware upgrade will remove"
    echo "  the plugin and nothing will reinstall it. Rebuild it as a package"
    echo "  once the box has working IPv4:"
    echo ""
    echo "    git clone https://github.com/hrko/ds-lite-opnsense.git"
    echo "    cd ds-lite-opnsense/os-dslite && ./tools/build-pkg.sh"
    echo "    pkg add -f dist/os-dslite-*.pkg"
fi

echo ""
echo "Next steps:"
echo "  1. Log out and back into the OPNsense web UI (the menu entry"
echo "     will not appear until you do)"
echo "  2. Go to Interfaces > DS-Lite > Settings"
echo "  3. Enable, pick your mode and WAN interface, click Save"
echo ""
echo "Prerequisites (Interfaces > [WAN]):"
echo "  - IPv4 Configuration Type: None"
echo "  - IPv6 Configuration Type: DHCPv6"
echo "  - Prefix delegation size: 56 (or whatever your ISP delegates)"
echo ""
echo "Fixed IP mode also needs, from your provisioning mail:"
echo "  - Interface ID, BR/AFTR address, and the fixed IPv4"
echo "  - the update URL plus its user/password, so the CE address"
echo "    re-registers automatically when your prefix changes"
echo ""
echo "After the tunnel is up, add a gateway on the DS-Lite interface"
echo "or nothing will monitor it and WAN failover will never trigger."
echo "See the README section 'Gateway and failover'."
echo ""
