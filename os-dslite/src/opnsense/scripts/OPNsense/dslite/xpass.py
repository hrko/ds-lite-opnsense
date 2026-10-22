#!/usr/local/bin/python3
"""Xpass fixed-IP registration. Never accepts credentials on the command line.

Protocol: Yamaha Xpass fixed-IP example (d=FQDN, p=password, a=IPv6, u=DDNS ID),
HTTP Basic authentication, HTTP 200 denotes acceptance. TLS is mandatory.
"""
import argparse
import ipaddress
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.parse import urlencode, urlsplit
import xml.etree.ElementTree as ET

CONFIG = Path('/conf/config.xml')
STATUS = Path('/var/run/dslite_prefix_update_status')


def settings(path=CONFIG):
    node = ET.parse(path).getroot().find('OPNsense/dslite')
    if node is None:
        raise ValueError('missing settings')
    return {child.tag: (child.text or '') for child in node}


def select_source(output, preferred=''):
    candidates = set()
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 2 or fields[0] != 'inet6':
            continue
        if set(fields) & {'tentative', 'duplicated', 'deprecated', 'temporary', 'detached'}:
            continue
        addr = ipaddress.IPv6Address(fields[1].split('%')[0])
        if addr in ipaddress.IPv6Network('2000::/3'):
            candidates.add(str(addr))
    if preferred:
        addr = str(ipaddress.IPv6Address(preferred))
        if addr not in candidates:
            raise ValueError('configured source is not a usable WAN address')
        return addr
    if len(candidates) != 1:
        raise ValueError('WAN needs one stable global IPv6 address or an explicit source')
    return candidates.pop()


def quote(value):
    # curl config grammar: reject control characters rather than allow injection.
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError('control character in configuration')
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def request_config(cfg, source):
    required = ['fixedip_update_url', 'fixedip_auth_user', 'fixedip_auth_pass',
                'xpass_fqdn', 'xpass_ddns_id', 'xpass_ddns_password']
    if any(not cfg.get(key) for key in required):
        raise ValueError('missing Xpass registration fields')
    url = cfg['fixedip_update_url']
    parsed = urlsplit(url)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.query or parsed.fragment):
        raise ValueError('update URL must be HTTPS without credentials, query or fragment')
    if ':' in cfg['fixedip_auth_user']:
        raise ValueError('Basic auth username cannot contain a colon')
    source = str(ipaddress.IPv6Address(source))
    query = urlencode({'d': cfg['xpass_fqdn'], 'p': cfg['xpass_ddns_password'],
                       'a': source, 'u': cfg['xpass_ddns_id']})
    return '\n'.join([
        'url = ' + quote(url + '?' + query),
        'user = ' + quote(cfg['fixedip_auth_user'] + ':' + cfg['fixedip_auth_pass']),
        'interface = ' + quote(source),
        'ipv6', 'basic', 'silent', 'connect-timeout = 5', 'max-time = 20',
        'proto = "=https"', 'output = "/dev/null"', 'write-out = "%{http_code}"',
    ]) + '\n'


def register(cfg, source, run=subprocess.run):
    # -q must be first: do not load root's .curlrc (proxy, insecure, redirects).
    # No URL, credentials, response body or raw curl errors reach argv/logs.
    result = run(['curl', '-q', '--config', '-'], input=request_config(cfg, source),
                 text=True, capture_output=True, timeout=25,
                 env={k: v for k, v in os.environ.items() if 'proxy' not in k.lower()})
    if result.returncode != 0:
        raise ValueError('Xpass HTTPS transport failed')
    if result.stdout.strip() != '200':
        raise ValueError('Xpass update was not accepted (HTTP status is not 200)')


def write_status(ok):
    # Only bounded, non-secret status. Atomic replacement; no response body.
    import tempfile
    with tempfile.NamedTemporaryFile(mode='w', dir=STATUS.parent, delete=False) as stream:
        name = stream.name
        stream.write(f'{int(time.time())} {0 if ok else 1} {"OK" if ok else "xpass-error"}\n')
    try:
        os.replace(name, STATUS)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['source', 'update'])
    parser.add_argument('interface')
    parser.add_argument('--source', help='Expected source selected by the tunnel configurator')
    args = parser.parse_args()
    try:
        cfg = settings()
        if cfg.get('enabled') != '1' or cfg.get('mode') != 'fixedip' or cfg.get('isp_profile') != 'xpass':
            raise ValueError('Xpass fixed-IP mode is not enabled')
        ipaddress.IPv6Address(cfg.get('fixedip_aftr', ''))
        ipaddress.IPv4Address(cfg.get('fixedip_v4', ''))
        result = subprocess.run(['ifconfig', args.interface], text=True, capture_output=True,
                                timeout=5, check=True)
        source = select_source(result.stdout, cfg.get('xpass_source_ipv6', ''))
        if args.action == 'source':
            print(source)
        else:
            if not args.source or source != str(ipaddress.IPv6Address(args.source)):
                raise ValueError('WAN source changed during configuration')
            register(cfg, source)
            write_status(True)
        return 0
    except (ValueError, OSError, ET.ParseError, subprocess.SubprocessError):
        # Exceptions can embed the URL/password; never stringify them here.
        if args.action == 'update':
            try:
                write_status(False)
            except OSError:
                pass
        print('Xpass operation failed; check settings, WAN IPv6 and HTTPS connectivity', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
