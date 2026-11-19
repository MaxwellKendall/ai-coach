"""TKL-794: downloads verify TLS without SSL_CERT_FILE on a python.org Python with no CA bundle.

  python3 -m unittest discover -s scripts/tests
"""
import importlib.util, os, ssl, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('higgsfield_demos', os.path.join(HERE, '..', 'higgsfield-demos.py'))
demos = importlib.util.module_from_spec(spec)
spec.loader.exec_module(demos)

NO_BUNDLE = ssl.DefaultVerifyPaths(None, None, 'SSL_CERT_FILE', '/nonexistent/cert.pem', 'SSL_CERT_DIR', '/nonexistent/certs')


class CAFileTests(unittest.TestCase):
    def test_falls_back_to_system_bundle_when_python_has_none(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch('ssl.get_default_verify_paths', return_value=NO_BUNDLE):
            self.assertEqual(demos.ca_file(), '/etc/ssl/cert.pem' if os.path.exists('/etc/ssl/cert.pem') else None)

    def test_respects_ssl_cert_file(self):
        with mock.patch.dict(os.environ, {'SSL_CERT_FILE': '/x.pem'}, clear=True), mock.patch('ssl.get_default_verify_paths', return_value=NO_BUNDLE):
            self.assertIsNone(demos.ca_file())

    def test_keeps_pythons_own_bundle(self):
        own = ssl.DefaultVerifyPaths(None, None, 'SSL_CERT_FILE', __file__, 'SSL_CERT_DIR', '/nonexistent/certs')
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch('ssl.get_default_verify_paths', return_value=own):
            self.assertIsNone(demos.ca_file())

    @unittest.skipUnless(os.path.exists('/etc/ssl/cert.pem'), 'needs /etc/ssl/cert.pem')
    def test_context_verifies_with_the_fallback(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch('ssl.get_default_verify_paths', return_value=NO_BUNDLE):
            ctx = demos.ssl_context()
        self.assertEqual(ctx.verify_mode, ssl.CERT_REQUIRED)
        self.assertGreater(ctx.cert_store_stats()['x509_ca'], 0)


if __name__ == '__main__':
    unittest.main()
