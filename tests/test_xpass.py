import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock, patch
import io
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('xpass', ROOT / 'os-dslite/src/opnsense/scripts/OPNsense/dslite/xpass.py')
xpass = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(xpass)


class XpassTest(unittest.TestCase):
    def setUp(self):
        self.cfg = dict(fixedip_update_url='https://update.example.test/update',
                        fixedip_auth_user='basic-user', fixedip_auth_pass='basic-secret',
                        xpass_fqdn='fqdn.example.test', xpass_ddns_id='ddns-id',
                        xpass_ddns_password='p&=+%"\\secret')
        self.source = '2001:db8::1'

    def test_source_filters_unusable_addresses(self):
        output = '\n'.join(['inet6 fe80::1%vtnet0 prefixlen 64',
                            'inet6 2001:db8::2 prefixlen 64 temporary',
                            'inet6 2001:db8::3 prefixlen 64 tentative',
                            'inet6 2001:db8::4 prefixlen 64 deprecated',
                            'inet6 2001:db8::5 prefixlen 64 duplicated',
                            'inet6 2001:db8::1 prefixlen 64'])
        self.assertEqual(xpass.select_source(output), self.source)

    def test_ambiguity_requires_explicit_address(self):
        output = 'inet6 2001:db8::1\ninet6 2001:db8::2'
        with self.assertRaises(ValueError):
            xpass.select_source(output)
        self.assertEqual(xpass.select_source(output, '2001:db8::2'), '2001:db8::2')
        with self.assertRaises(ValueError):
            xpass.select_source(output, '2001:db8::3')
        with self.assertRaises(ValueError):
            xpass.select_source('inet6 fe80::1')

    def test_query_fields_and_escaping(self):
        config = xpass.request_config(self.cfg, self.source)
        url = config.splitlines()[0][7:-1]
        query = parse_qs(urlsplit(url).query)
        self.assertEqual(query, {'d': ['fqdn.example.test'], 'u': ['ddns-id'],
                                'p': [self.cfg['xpass_ddns_password']], 'a': [self.source]})
        self.assertNotIn('insecure', config)
        self.assertNotIn('location', config)

    def test_rejects_unsafe_urls_and_missing_credentials(self):
        for url in ['http://example.test/', 'https://u:p@example.test/',
                    'https://example.test/?a=b', 'https://example.test/#x']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                xpass.request_config(dict(self.cfg, fixedip_update_url=url), self.source)
        with self.assertRaises(ValueError):
            xpass.request_config(dict(self.cfg, fixedip_auth_pass='a\ninsecure'), self.source)
        with self.assertRaises(ValueError):
            xpass.request_config(dict(self.cfg, xpass_ddns_id=''), self.source)

    def test_http_errors_and_redirects_are_not_success(self):
        for status in ['204', '301', '401', '403', '500', '000']:
            runner = Mock(return_value=subprocess.CompletedProcess([], 0, status, ''))
            with self.subTest(status=status), self.assertRaises(ValueError):
                xpass.register(self.cfg, self.source, runner)

    def test_transport_error_is_not_success(self):
        runner = Mock(return_value=subprocess.CompletedProcess([], 60, '200', 'secret'))
        with self.assertRaisesRegex(ValueError, '^Xpass HTTPS transport failed$'):
            xpass.register(self.cfg, self.source, runner)

    def test_credentials_only_on_stdin_and_periodic_refresh(self):
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, '200', ''))
        for _ in range(2):
            xpass.register(self.cfg, self.source, runner)
        self.assertEqual(runner.call_count, 2)
        self.assertEqual(runner.call_args.args[0], ['curl', '-q', '--config', '-'])
        self.assertNotIn('basic-secret', str(runner.call_args.args))
        self.assertIn('basic-secret', runner.call_args.kwargs['input'])

    def test_xml_documents_parse(self):
        for path in (ROOT/'os-dslite/src').rglob('*.xml'):
            with self.subTest(path=path):
                xpass.ET.parse(path)

    def test_changed_source_does_not_register(self):
        cfg = dict(self.cfg, enabled='1', mode='fixedip', isp_profile='xpass',
                   fixedip_aftr='2001:db8::100', fixedip_v4='192.0.2.1')
        with patch.object(xpass, 'settings', return_value=cfg), \
             patch.object(xpass.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'inet6 2001:db8::2', '')), \
             patch.object(xpass, 'register') as register, \
             patch.object(xpass, 'write_status') as status, \
             patch.object(xpass.sys, 'argv', ['xpass.py', 'update', 'vtnet0', '--source', self.source]), \
             patch.object(xpass.sys, 'stderr', io.StringIO()) as error:
            self.assertEqual(xpass.main(), 1)
            register.assert_not_called()
            status.assert_called_once_with(False)
            self.assertNotIn('basic-secret', error.getvalue())

    def test_timeout_does_not_expose_request(self):
        cfg = dict(self.cfg, enabled='1', mode='fixedip', isp_profile='xpass',
                   fixedip_aftr='2001:db8::100', fixedip_v4='192.0.2.1')
        with patch.object(xpass, 'settings', return_value=cfg), \
             patch.object(xpass.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'inet6 2001:db8::1', '')), \
             patch.object(xpass, 'register', side_effect=subprocess.TimeoutExpired('basic-secret', 25)), \
             patch.object(xpass, 'write_status') as status, \
             patch.object(xpass.sys, 'argv', ['xpass.py', 'update', 'vtnet0', '--source', self.source]), \
             patch.object(xpass.sys, 'stderr', io.StringIO()) as error:
            self.assertEqual(xpass.main(), 1)
            status.assert_called_once_with(False)
            self.assertNotIn('basic-secret', error.getvalue())


if __name__ == '__main__':
    unittest.main()
