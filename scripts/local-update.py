#!/usr/bin/env python3
"""Build, verify and replace one local installation using Apple Development."""
import argparse
from datetime import datetime, timezone
import fcntl
import json
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / '.local-update'
APP_NAME = 'MonitorControlPlus.app'
BUNDLE_ID = 'local.mateusz.MonitorControlPlus'


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def output(*args):
    return run(*args, capture_output=True, text=True).stdout


def app_info(path):
    with (path / 'Contents/Info.plist').open('rb') as file:
        return plistlib.load(file)


def signing_identity(requested=None):
    identities = re.findall(r'\d+\) ([A-F0-9]{40}) "(Apple Development:[^"]+)"',
                            output('security', 'find-identity', '-v', '-p', 'codesigning'))
    if requested:
        identities = [entry for entry in identities if requested in entry]
    if len(identities) != 1:
        raise RuntimeError('Choose one valid Apple Development identity using --identity HASH. '
                           'Create it in Xcode > Settings > Apple Accounts > Manage Certificates if necessary.')
    fingerprint, name = identities[0]
    certificate = run('security', 'find-certificate', '-c', name, '-p', capture_output=True).stdout
    subject = run('openssl', 'x509', '-noout', '-subject', '-nameopt', 'RFC2253',
                  input=certificate, capture_output=True).stdout.decode()
    match = re.search(r'(?:^|,)OU=([A-Z0-9]{10})(?:,|$)', subject)
    if not match:
        raise RuntimeError('Cannot determine the signing certificate Team ID.')
    return fingerprint, match.group(1)


def verify(app, team):
    if app_info(app)['CFBundleIdentifier'] != BUNDLE_ID:
        raise RuntimeError('Unexpected application bundle identifier.')
    try:
        run('codesign', '--verify', '--deep', '--strict', app, capture_output=True)
    except subprocess.CalledProcessError as error:
        raise RuntimeError(error.stderr.decode().strip()) from error
    details = run('codesign', '-dv', '--verbose=2', app, capture_output=True).stderr.decode()
    if f'TeamIdentifier={team}\n' not in details or 'Authority=Apple Development:' not in details:
        raise RuntimeError('The application is not signed by the selected Apple Development team.')


def save_state(state):
    temporary = STATE / 'state.json.tmp'
    temporary.write_text(json.dumps(state, indent=2) + '\n')
    temporary.replace(STATE / 'state.json')


def source_snapshot():
    paths = [ROOT / 'MonitorControl.xcodeproj/project.pbxproj']
    for folder in ('MonitorControl', 'MonitorControlHelper', 'scripts'):
        paths.extend(p for p in (ROOT / folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
    snapshot = {}
    for path in paths:
        try:
            stat = path.stat()
            snapshot[str(path)] = (stat.st_mtime_ns, stat.st_size)
        except FileNotFoundError:
            pass  # Editors can atomically replace a file between discovery and stat.
    return snapshot


def source_revision():
    return hashlib.sha256(json.dumps(source_snapshot(), sort_keys=True).encode()).hexdigest()


def cleanup_updates(install_dir, keep=3):
    """Prune only recognized Plus staging bundles, after a verified launch."""
    stages = []
    for stage in install_dir.glob('.MonitorControlPlus-update-*'):
        if stage.is_symlink() or not stage.is_dir():
            continue
        children = list(stage.iterdir())
        if not children or any(child.name not in (APP_NAME, 'previous.app', 'failed.app') for child in children):
            continue
        try:
            if any(child.is_symlink() or app_info(child).get('CFBundleIdentifier') != BUNDLE_ID for child in children):
                continue
        except (OSError, plistlib.InvalidFileException):
            continue
        stages.append(stage)
    stages.sort(key=lambda path: path.stat().st_mtime_ns, reverse=True)
    for stage in stages[keep:]:
        shutil.rmtree(stage)


def install(args, candidate, team):
    destination = args.install_dir.expanduser().resolve() / APP_NAME
    stage = candidate.parent
    verify(candidate, team)
    if destination.exists():
        requirement_result = run('codesign', '-d', '-r-', destination, capture_output=True)
        requirement = (requirement_result.stdout + requirement_result.stderr).decode()
        designated = next((line.removeprefix('designated => ') for line in requirement.splitlines()
                           if line.startswith('designated => ')), None)
        if not designated:
            raise RuntimeError('The installed app has no designated signing requirement.')
        run('codesign', '--verify', '-R', '=' + designated, candidate)

    helper = STATE / 'app-lifecycle'
    run('xcrun', 'swiftc', ROOT / 'scripts/AppLifecycle.swift', '-o', helper)
    run(helper, 'quit')
    backups = STATE / 'preferences-backups'
    backups.mkdir(exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    for domain in (BUNDLE_ID, 'app.monitorcontrol.MonitorControl'):
        subprocess.run(['defaults', 'export', domain, str(backups / f'{stamp}-{domain}.plist')],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    previous = stage / 'previous.app'
    try:
        if destination.exists():
            destination.rename(previous)
        candidate.rename(destination)
        verify(destination, team)
        run('open', '-n', destination)
        time.sleep(2)
        run(helper, 'check', destination)
    except Exception:
        # Keep the failed candidate for diagnosis and restore the previous installation.
        if previous.exists():
            if destination.exists():
                destination.rename(stage / 'failed.app')
            previous.rename(destination)
            subprocess.run(['open', '-n', str(destination)])
        raise
    try:
        cleanup_updates(destination.parent)
    except OSError as error:
        print(f'Old update cleanup skipped: {error}', file=sys.stderr)
    print(f'Updated and launched {destination}. Previous app retained at {previous if previous.exists() else "(first install)"}')


def update(args, state):
    identity, team = signing_identity(args.identity or state.get('identity'))
    destination = args.install_dir.expanduser().resolve() / APP_NAME
    if destination.exists() and app_info(destination)['CFBundleIdentifier'] != BUNDLE_ID:
        raise RuntimeError(f'Refusing to replace an unrelated app at {destination}.')
    revision = source_revision()
    pending = state.get('pending', {})
    candidate = Path(pending.get('candidate', ''))
    if not args.build_only and pending.get('source') == revision and pending.get('destination') == str(destination) and candidate.is_dir():
        # Accept only staging directories created by this updater beside this installation.
        if candidate.name != APP_NAME or candidate.parent.parent != destination.parent or not candidate.parent.name.startswith('.MonitorControlPlus-update-'):
            raise RuntimeError('Unexpected pending update path.')
        try:
            install(args, candidate, team)
        finally:
            if not candidate.exists():
                state.pop('pending', None)
                save_state(state)
        return
    state.pop('pending', None)
    installed_number = int(app_info(destination)['CFBundleVersion']) if destination.exists() else 0
    number = max(7152, installed_number, state.get('build', 0)) + 1
    state.update(identity=identity, team=team, build=number)
    save_state(state)
    derived = STATE / 'DerivedData'
    log = STATE / 'build.log'
    command = [
        'xcodebuild', '-project', ROOT / 'MonitorControl.xcodeproj', '-scheme', 'MonitorControl',
        '-configuration', 'Debug', '-derivedDataPath', derived,
        '-clonedSourcePackagesDirPath', STATE / 'SourcePackages',
        '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile',
        'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGNING_REQUIRED=YES', 'CODE_SIGN_STYLE=Manual',
        f'CODE_SIGN_IDENTITY={identity}', f'DEVELOPMENT_TEAM={team}',
        f'CURRENT_PROJECT_VERSION={number}', 'MACOSX_DEPLOYMENT_TARGET=12.0', 'build',
    ]
    print(f'Building {APP_NAME} ({number}), Apple Development team {team}…', flush=True)
    with log.open('w') as file:
        try:
            run(*command, stdout=file, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError:
            print('\n'.join(log.read_text().splitlines()[-35:]), file=sys.stderr)
            raise RuntimeError(f'Build failed; existing installation was not changed. See {log}')
    built = derived / 'Build/Products/Debug' / APP_NAME
    verify(built, team)
    if args.build_only:
        print(f'Verified signed build: {built}')
        return
    # Stage on the destination volume. Never merge new files into the old bundle.
    stage = Path(tempfile.mkdtemp(prefix='.MonitorControlPlus-update-', dir=destination.parent))
    candidate = stage / APP_NAME
    run('ditto', built, candidate)
    verify(candidate, team)
    state['pending'] = {'candidate': str(candidate), 'source': revision, 'destination': str(destination)}
    save_state(state)
    try:
        install(args, candidate, team)
    finally:
        if not candidate.exists():
            state.pop('pending', None)
            save_state(state)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity', help='Apple Development certificate SHA-1 or exact name; remembered after selection')
    parser.add_argument('--install-dir', type=Path, default=Path('/Applications'))
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--watch', action='store_true', help='Rebuild, replace and restart after source changes')
    args = parser.parse_args()
    STATE.mkdir(exist_ok=True)
    with (STATE / 'update.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another local update process is already running.')
        state_file = STATE / 'state.json'
        state = json.loads(state_file.read_text()) if state_file.exists() else {}
        watch_updates(args, state)


def watch_updates(args, state):
    snapshot = None
    retry_at = None
    retry_delay = 5
    while True:
        current = source_snapshot()
        changed = current != snapshot
        if changed and snapshot is not None:
            time.sleep(0.5)
            current = source_snapshot()
        if changed or (retry_at is not None and time.monotonic() >= retry_at):
            snapshot = current
            try:
                update(args, state)
                retry_at = None
                retry_delay = 5
            except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
                if not args.watch:
                    raise
                print(f'Update failed: {error}; retrying in {retry_delay}s', file=sys.stderr, flush=True)
                retry_at = time.monotonic() + retry_delay
                retry_delay = min(60, retry_delay * 2)
        if not args.watch:
            return
        time.sleep(1)



if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass
    except (RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
