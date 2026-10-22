# Xpass fixed IP (experimental)

This fork starts from kawaii-not-kawaii/ds-lite-opnsense at
`df5aedc51935b66b87efd94070fbef2448a4c76f`. The Xpass registration implementation
is new; it does not copy the implementation from wjyzxcv's fork.

Select Fixed IP mode and the explicit Xpass ISP profile. Configure the contract's
AFTR IPv6, fixed IPv4, HTTPS update URL, HTTP Basic credentials, FQDN, DDNS ID and
DDNS password. Basic credentials and DDNS credentials are separate. No subscriber
values are supplied by this repository. Interface ID is unused in this mode.

The source is an existing non-temporary, non-deprecated global WAN IPv6 address.
If there is more than one candidate, specify one in Xpass WAN source IPv6. That
override must be updated after renumbering; no synthetic WAN alias is created.
Initial configuration fails safely until a usable address is available. WAN hooks
and the periodic job retry later. Periodic updates refresh even unchanged IPv6
addresses, and reconfigure the tunnel when its recorded source changes.

The request follows [Yamaha's Xpass fixed-IP example](https://www.rtpro.yamaha.co.jp/RT/docs/xpass/index.html):
`d=FQDN`, `p=DDNS password`, `a=source IPv6`, `u=DDNS ID`, plus Basic authentication.
Only HTTP 200 is accepted, consistent with that example. The response body is
discarded, not interpreted as DynDNS `good`/`nochg`. HTTPS verification is mandatory;
redirects and ambient proxy settings are not used. Secrets go to curl over stdin,
never argv, and errors/logs do not echo response bodies or credentials.

Configure **Source NAT and MSS in OPNsense itself**. Xpass mode ignores plugin NAT
and clears only the plugin's NAT/filter anchors; it does not create endpoint-independent
NAT rules itself. This allows the core's UDP endpoint-independent option to be used.
Assign the gif interface and verify gateway/default-route behavior on the target
OPNsense release. This remains a single-tunnel plugin, not concurrent Xpass + DS-Lite.

Configure, periodic update and teardown share a lock. Existing upstream tunnel,
gateway and service-controller behavior remains; this change is not a full audit
of other providers or an assurance of GUI error reporting in every failure case.

## Build and validation

Prefer an offline source build using `DSLITE_BUILD_ONLY=1 sh os-dslite/install.sh`
on an OPNsense test system, or `make -C os-dslite pkg`. Network installation requires
`DSLITE_BRANCH` set to a reviewed 40-character commit SHA from this fork.
Do not execute the installer on a production gateway merely to test packaging.

Run `python3 -m unittest discover -s tests -v` and `sh -n` for shell scripts.
Unit tests mock all network I/O. They cover address selection, URL validation,
credential transport, query encoding, HTTP/transport failure and repeated updates.
FreeBSD/OPNsense package installation, live Xpass registration, PF/NAT/MSS,
reboot, renumbering, gateway monitoring and VM migration require lab validation.
Never run old and new registration clients simultaneously for one subscription.
