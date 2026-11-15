import importlib.util
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('local_update', Path(__file__).resolve().parents[1] / 'scripts/local-update.py')
update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update)


class SigningTests(unittest.TestCase):
    def test_no_valid_certificate_fails_instead_of_using_ad_hoc(self):
        with patch.object(update, 'output', return_value='0 valid identities found'):
            with self.assertRaisesRegex(RuntimeError, 'Apple Development'):
                update.signing_identity()

    def test_certificate_selection_is_pinned(self):
        listing = ('1) ' + 'A' * 40 + ' "Apple Development: First"\n'
                   '2) ' + 'B' * 40 + ' "Apple Development: Second"\n')
        def invoke(*args, **kwargs):
            if args[0] == 'security':
                self.assertIn('Apple Development: Second', args)
                return subprocess.CompletedProcess(args, 0, stdout=b'PUBLIC CERTIFICATE')
            return subprocess.CompletedProcess(args, 0, stdout=b'subject=CN=Second,OU=ABCDEFGHIJ,O=Example\n')
        with patch.object(update, 'output', return_value=listing), patch.object(update, 'run', side_effect=invoke):
            self.assertEqual(update.signing_identity('B' * 40), ('B' * 40, 'ABCDEFGHIJ'))
            with self.assertRaises(RuntimeError):
                update.signing_identity()
            with self.assertRaises(RuntimeError):
                update.signing_identity('C' * 40)

    def test_wrong_team_is_rejected_after_integrity_verification(self):
        with patch.object(update, 'app_info', return_value={'CFBundleIdentifier': update.BUNDLE_ID}), \
             patch.object(update, 'run', return_value=subprocess.CompletedProcess([], 0, stderr=b'TeamIdentifier=OTHERTEAM\nAuthority=Apple Development: Other\n')):
            with self.assertRaisesRegex(RuntimeError, 'selected Apple Development team'):
                update.verify(Path('/tmp/test.app'), 'ABCDEFGHIJ')


class InstallationTests(unittest.TestCase):
    def test_failed_launch_restores_previous_complete_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state_dir = root / 'state'
            state_dir.mkdir()
            install_dir = root / 'Applications'
            install_dir.mkdir()
            destination = install_dir / update.APP_NAME
            built = state_dir / 'DerivedData/Build/Products/Debug' / update.APP_NAME
            for app, version in ((destination, '7156'), (built, '7157')):
                (app / 'Contents').mkdir(parents=True)
                (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                    'CFBundleIdentifier': update.BUNDLE_ID, 'CFBundleVersion': version,
                }))
            def invoke(*args, **kwargs):
                if args[0] == 'ditto':
                    shutil.copytree(args[1], args[2])
                if args[0] == 'codesign' and '-r-' in args:
                    return subprocess.CompletedProcess(args, 0, stdout=b'designated => identifier "test"\n', stderr=b'')
                if 'check' in args:
                    raise RuntimeError('Simulated failed launch')
                return subprocess.CompletedProcess(args, 0)
            args = argparse.Namespace(identity=None, install_dir=install_dir, build_only=False)
            with patch.object(update, 'STATE', state_dir), \
                 patch.object(update, 'signing_identity', return_value=('A' * 40, 'ABCDEFGHIJ')), \
                 patch.object(update, 'run', side_effect=invoke), \
                 patch.object(update, 'verify'), patch.object(update.time, 'sleep'), \
                 patch.object(update.subprocess, 'run'):
                with self.assertRaisesRegex(RuntimeError, 'Simulated failed launch'):
                    update.update(args, {'build': 7156})
            self.assertEqual(update.app_info(destination)['CFBundleVersion'], '7156')
            self.assertTrue(list(install_dir.glob('.MonitorControlPlus-update-*/failed.app')))


if __name__ == '__main__':
    unittest.main()
