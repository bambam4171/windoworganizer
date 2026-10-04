"""Checks for the bundling and signing tools (WO-S2). Temp folders only: no Keychain, no real app, no codesign run.

    /usr/bin/python3 tools/check_tools.py
"""
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_app  # noqa: E402
import make_local_identity  # noqa: E402

LISTING_WITH = '''  1) 3F2A… "Apple Development: someone"
  2) 9C1B… "WindowOrganizer Local"
     2 valid identities found
'''
LISTING_WITHOUT = '''  1) 3F2A… "Apple Development: someone"
     1 valid identities found
'''


class Refuse:
    """Stands in for subprocess.run: records the call and fails the test if anything would run."""

    def __init__(self):
        self.calls = []

    def __call__(self, *args, **kwargs):
        self.calls.append(args)
        raise AssertionError('a command ran: %r' % (args,))


class MakeAppChecks(unittest.TestCase):
    def test_plist_is_a_menu_bar_app_with_a_fixed_identifier(self):
        info = plistlib.loads(make_app.info_plist('0.2').encode())
        self.assertEqual(info['CFBundleIdentifier'], 'local.windoworganizer.app')
        self.assertEqual(info['CFBundleExecutable'], 'WindowOrganizer')
        self.assertEqual(info['CFBundleShortVersionString'], '0.2')
        self.assertIs(info['LSUIElement'], True)
        self.assertEqual(info['CFBundleVersion'], '8')
        self.assertEqual(info['CFBundleIconFile'], 'AppIcon')
        self.assertIs(info['NSHighResolutionCapable'], True)

    def test_identity_is_used_when_listed_else_ad_hoc(self):
        self.assertEqual(make_app.choose_identity(LISTING_WITH), 'WindowOrganizer Local')
        self.assertEqual(make_app.choose_identity(LISTING_WITHOUT), '-')
        self.assertEqual(make_app.choose_identity('"WindowOrganizer Local (old)"'), '-')

    def test_sign_command(self):
        app = Path('/tmp/x/WindowOrganizer.app')
        self.assertEqual(make_app.sign_command(app, 'WindowOrganizer Local'),
                         ['/usr/bin/codesign', '--force', '--sign', 'WindowOrganizer Local', str(app)])

    def test_bundle_replaces_the_binary_instead_of_overwriting_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            binary = tmp / 'WindowOrganizer'
            binary.write_text('new')
            app = tmp / 'out' / 'WindowOrganizer.app'
            exe = app / 'Contents' / 'MacOS' / 'WindowOrganizer'
            exe.parent.mkdir(parents=True)
            exe.write_text('old')
            old_inode = exe.stat().st_ino
            keep = tmp / 'hold'
            os.link(exe, keep)   # holds the old inode, as a running app would
            make_app.bundle(binary, app, '0.2')
            self.assertEqual(exe.read_text(), 'new')
            self.assertNotEqual(exe.stat().st_ino, old_inode)
            self.assertEqual(keep.read_text(), 'old')
            self.assertTrue((app / 'Contents' / 'Info.plist').is_file())

    def test_default_app_lives_in_the_dev_state_folder(self):
        self.assertEqual(make_app.APP, Path.home() / 'DevOps/Dev/.state/WindowOrganizer/WindowOrganizer.app')


class IdentityChecks(unittest.TestCase):
    def test_dry_run_runs_nothing_and_names_every_step(self):
        refuse = Refuse()
        with tempfile.TemporaryDirectory() as tmp:
            out = make_local_identity.main(['--keychain', str(Path(tmp) / 'k.keychain-db')], run=refuse)
        self.assertEqual(refuse.calls, [])
        self.assertIn('openssl req', out)
        self.assertIn('security import', out)
        self.assertIn('security add-trusted-cert -p codeSign', out)
        self.assertIn('--create', out)

    def test_certificate_is_for_code_signing(self):
        with tempfile.TemporaryDirectory() as tmp:
            cert, p12, password = make_local_identity.make_certificate(tmp, 'WO Check Local')
            text = subprocess.run(['openssl', 'x509', '-in', str(cert), '-noout', '-text'],
                                  capture_output=True, text=True, check=True).stdout
            self.assertIn('Code Signing', text)
            self.assertIn('CN=WO Check Local', text.replace(' = ', '='))
            self.assertTrue(Path(p12).stat().st_size > 0)
            self.assertTrue(password)

    def test_default_keychain_is_the_login_keychain_but_only_with_create(self):
        self.assertEqual(make_local_identity.LOGIN_KEYCHAIN, Path.home() / 'Library/Keychains/login.keychain-db')
        self.assertEqual(make_local_identity.NAME, 'WindowOrganizer Local')


class ReviewIdentityChecks(unittest.TestCase):
    def test_no_swift_source_carries_the_review_identity(self):
        root = Path(__file__).resolve().parent.parent
        hits = []
        for f in sorted((root / 'Sources').rglob('*.swift')):
            if f.name in ('Migration.swift', 'Migrate.swift'):
                continue   # GPT-WO-S4: the one place that must name the review app, to copy out of it
            for n, line in enumerate(f.read_text().splitlines(), 1):
                low = line.lower()
                if 'gptreview' in low or 'review edition' in low or 'windoworganizer.review' in low:
                    hits.append('%s:%d' % (f.relative_to(root), n))
        self.assertEqual(hits, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
