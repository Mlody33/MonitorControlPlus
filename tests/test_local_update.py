import importlib.util
import argparse
from pathlib import Path
import plistlib
import os
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


class WatchTests(unittest.TestCase):
    def test_initial_failure_retries_without_another_source_edit(self):
        clock = [0]
        args = argparse.Namespace(watch=True)
        def sleep(seconds):
            clock[0] += seconds
        with patch.object(update, 'source_snapshot', return_value={'unchanged': (1, 1)}), \
             patch.object(update.time, 'sleep', side_effect=sleep), \
             patch.object(update.time, 'monotonic', side_effect=lambda: clock[0]), \
             patch.object(update, 'update', side_effect=[RuntimeError('quit timeout'), KeyboardInterrupt]) as attempt:
            with self.assertRaises(KeyboardInterrupt):
                update.watch_updates(args, {})
        self.assertEqual(attempt.call_count, 2)
        self.assertGreaterEqual(clock[0], 5)

    def test_single_update_still_reports_failure(self):
        with patch.object(update, 'source_snapshot', return_value={}), \
             patch.object(update, 'update', side_effect=RuntimeError('build failed')):
            with self.assertRaisesRegex(RuntimeError, 'build failed'):
                update.watch_updates(argparse.Namespace(watch=False), {})


class RetryAndCleanupTests(unittest.TestCase):
    def test_quit_timeout_retries_install_without_rebuilding(self):
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
            builds = []
            quits = []
            def invoke(*args, **kwargs):
                if args[0] == 'xcodebuild':
                    builds.append(args)
                if args[0] == 'ditto':
                    shutil.copytree(args[1], args[2])
                if args[0] == 'codesign' and '-r-' in args:
                    return subprocess.CompletedProcess(args, 0, stdout=b'designated => identifier "test"\n', stderr=b'')
                if args[-1] == 'quit':
                    quits.append(args)
                    if len(quits) == 1:
                        raise subprocess.CalledProcessError(1, args)
                return subprocess.CompletedProcess(args, 0)
            args = argparse.Namespace(identity=None, install_dir=install_dir, build_only=False)
            state = {'build': 7156}
            with patch.object(update, 'STATE', state_dir), \
                 patch.object(update, 'source_revision', return_value='same source'), \
                 patch.object(update, 'signing_identity', return_value=('A' * 40, 'ABCDEFGHIJ')), \
                 patch.object(update, 'run', side_effect=invoke), \
                 patch.object(update, 'verify'), patch.object(update.time, 'sleep'), \
                 patch.object(update.subprocess, 'run'):
                with self.assertRaises(subprocess.CalledProcessError):
                    update.update(args, state)
                candidate = Path(state['pending']['candidate'])
                self.assertTrue(candidate.is_dir())
                self.assertEqual(update.app_info(destination)['CFBundleVersion'], '7156')
                update.update(args, state)
            self.assertEqual(len(builds), 1)
            self.assertEqual(len(quits), 2)
            self.assertEqual(update.app_info(destination)['CFBundleVersion'], '7157')
            self.assertNotIn('pending', state)

    def test_cleanup_retains_three_bundles_and_leaves_unknown_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stages = []
            for number in range(6):
                stage = root / f'.MonitorControlPlus-update-{number}'
                contents = stage / 'previous.app/Contents'
                contents.mkdir(parents=True)
                (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': update.BUNDLE_ID}))
                os.utime(stage, (number + 1, number + 1))
                stages.append(stage)
            unknown = root / '.MonitorControlPlus-update-user-files'
            unknown.mkdir()
            (unknown / 'keep.txt').write_text('unrelated')
            symlink = root / '.MonitorControlPlus-update-link'
            symlink.symlink_to(stages[-1], target_is_directory=True)
            update.cleanup_updates(root)
            self.assertTrue(all(not stage.exists() for stage in stages[:3]))
            self.assertTrue(all(stage.exists() for stage in stages[3:]))
            self.assertTrue((unknown / 'keep.txt').exists())
            self.assertTrue(symlink.is_symlink())


if __name__ == '__main__':
    unittest.main()
