# Local updates for MonitorControlPlus

Run from the repository root:

```sh
python3 scripts/local-update.py
```

This builds a Debug app, signs it with Apple Development, verifies its complete
signature, stages a new bundle, quits the previous Plus process, replaces
`/Applications/MonitorControlPlus.app` and launches that exact path. It leaves
the original `/Applications/MonitorControl.app` alone. No sudo is used.

For automatic rebuild/restart after saving application sources:

```sh
python3 scripts/local-update.py --watch
```

Stop the watcher with Ctrl+C. A build failure leaves the installed application
untouched. Only one updater/watcher may run at a time.

Other options:

```sh
python3 scripts/local-update.py --build-only
python3 scripts/local-update.py --identity CERTIFICATE_SHA1
python3 scripts/local-update.py --install-dir "$HOME/Applications"
```

Use the same installation directory on subsequent updates. The first successful
identity selection is remembered in `.local-update/state.json`; it is not a
private key. Private signing keys stay in the login Keychain. The script requires
a valid Apple Development identity and never falls back to ad-hoc signing.

## One-time signing setup

In Xcode Settings > Apple Accounts, sign in, select your team, then use Manage
Certificates to create an Apple Development certificate. If macOS asks whether
`codesign` may use the signing key, approve that request yourself. An Always Allow
choice avoids repeated key-access prompts for the system signing tool.

If `security find-identity -v -p codesigning` does not list the certificate, check
its expiry and certificate chain. This machine required Apple's WWDR G3
intermediate, obtained from https://www.apple.com/certificateauthority/ and
verified before import. Do not replace trust settings with Always Trust.

The selected team must match the certificate. The script derives the Team ID
from its public certificate; the project is currently configured for the local
C5A6GBX9B2 team as well. A certificate renewal/signing identity change requires
an explicit `--identity` selection and may require another privacy permission
grant; the updater rejects a candidate that fails the installed app's designated
requirement.

## Preferences and permissions

The permanent app bundle identifier is `local.mateusz.MonitorControlPlus`.
On first launch, existing settings from `app.monitorcontrol.MonitorControl` are
copied once. Existing Plus values win; the original domain is not changed.
Subsequent builds do not import again, and lower build numbers do not erase
settings. Safe mode and the explicit reset command retain their reset behavior.

The new app identity needs its own one-time Device Control and Data Access
permission (formerly Accessibility) for native media keys. Grant it to the
installed app after the first signed installation. The updater does not grant
permissions or modify the macOS privacy database. A stable Apple Development
signature allows subsequent builds to satisfy the same designated requirement;
verify permission retention after the first actual upgrade on your macOS version.

Automatic Sparkle updates from the original MonitorControl project are disabled
and its feed/key removed. Updates come from this local script.

## Build state and recovery

`.local-update/` is ignored by Git. It contains DerivedData, dependency checkouts,
a monotonic build counter, the selected signing identity, the build log, and
pre-update preferences exports. The counter advances even if a build fails.
The script does not edit checked-in Info.plist files to number builds.

Old bundles are retained as `previous.app` inside a hidden
`.MonitorControlPlus-update-*` directory beside the installation. If replacement
or launch verification fails, the updater restores that previous bundle.
Preference exports live in `.local-update/preferences-backups/`.

Do not merge new bundle files into an existing signed .app, and do not edit the
installed app after signing. The script verifies a complete staged replacement.

## Checks

```sh
python3 -m unittest discover -s tests -v
xcrun swiftc MonitorControl/Enums/PrefKey.swift \
  MonitorControl/Support/PreferencesMigration.swift tests/PreferencesTests.swift \
  -o /tmp/monitor-preferences-tests
/tmp/monitor-preferences-tests
codesign --verify --deep --strict --verbose=2 /Applications/MonitorControlPlus.app
```

## Verified on this Mac

On 2026-11-15, macOS 27.2.1, the signed installation was updated from build 7156
to 7157 using Apple Development team C5A6GBX9B2. The CodeDirectory hashes changed,
the designated requirement stayed identical, seven saved display preference
values plus a temporary continuity marker survived, and the new app process
reported `AXIsProcessTrustedWithOptions` as true after the upgrade. The temporary
marker was then removed. Migration and rollback/signing tests passed.

Input source checks:

```sh
xcrun swiftc MonitorControl/Enums/Command.swift MonitorControl/Model/DDCInputSource.swift \
  tests/InputSourceTests.swift -o /tmp/monitor-input-tests
/tmp/monitor-input-tests
xcrun swiftc MonitorControl/Enums/Command.swift MonitorControl/Model/DDCInputSource.swift \
  MonitorControl/Model/OtherDisplay+InputSource.swift tests/InputSourceOperationTests.swift \
  -o /tmp/monitor-input-operation-tests
/tmp/monitor-input-operation-tests
```

The operation tests compile the production switching implementation against fake
DDC transports and virtualize its retry delays; they do not touch real displays.

DPMS operation checks (simulated DDC; no real power changes):

```sh
xcrun swiftc MonitorControl/Enums/Command.swift MonitorControl/Model/OtherDisplay+Power.swift \
  tests/DisplayPowerTests.swift -o /tmp/monitor-power-tests
/tmp/monitor-power-tests
```
