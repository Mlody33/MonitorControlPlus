// Copyright © MonitorControl contributors.

import Foundation

let localAppBundleIdentifier = "local.mateusz.MonitorControlPlus"
let preferencesMigrationKey = "MonitorControlPlus.preferencesMigrated"
let usesLocalUpdates = Bundle.main.bundleIdentifier == localAppBundleIdentifier

func preparePreferences(_ defaults: UserDefaults, bundleIdentifier: String?, legacyIdentifier: String = "app.monitorcontrol.MonitorControl", targetIdentifier: String = localAppBundleIdentifier) -> UserDefaults {
  guard bundleIdentifier == targetIdentifier, !defaults.bool(forKey: preferencesMigrationKey) else {
    return defaults
  }
  // Copy once, preserving any settings already made in Plus and leaving the
  // original MonitorControl preferences untouched.
  let existing = defaults.persistentDomain(forName: targetIdentifier) ?? [:]
  if let legacy = defaults.persistentDomain(forName: legacyIdentifier) {
    for (key, value) in legacy where existing[key] == nil {
      defaults.set(value, forKey: key)
    }
  }
  defaults.set(false, forKey: PrefKey.SUEnableAutomaticChecks.rawValue)
  defaults.set(true, forKey: preferencesMigrationKey)
  return defaults
}
