import Foundation

@main
struct PreferencesTests {
  static func main() {
    let prefix = "local.MonitorControlPlus.tests.\(UUID().uuidString)"
    let legacyID = prefix + ".legacy"
    let targetID = prefix + ".target"
    let defaults = UserDefaults(suiteName: targetID)!
    defer {
      defaults.removePersistentDomain(forName: targetID)
      defaults.removePersistentDomain(forName: legacyID)
    }
    let original: [String: Any] = ["friendlyName": "Console screen", "hideVolume": true, "SUEnableAutomaticChecks": true]
    defaults.setPersistentDomain(original, forName: legacyID)
    defaults.set("My existing name", forKey: "friendlyName")
    _ = preparePreferences(defaults, bundleIdentifier: targetID, legacyIdentifier: legacyID, targetIdentifier: targetID)
    assert(defaults.string(forKey: "friendlyName") == "My existing name")
    assert(defaults.bool(forKey: "hideVolume"))
    assert(!defaults.bool(forKey: "SUEnableAutomaticChecks"))
    assert(defaults.bool(forKey: preferencesMigrationKey))
    assert(NSDictionary(dictionary: defaults.persistentDomain(forName: legacyID)!).isEqual(to: original))
    defaults.set(false, forKey: "hideVolume")
    _ = preparePreferences(defaults, bundleIdentifier: targetID, legacyIdentifier: legacyID, targetIdentifier: targetID)
    assert(!defaults.bool(forKey: "hideVolume"), "Migration must not overwrite later edits")
    defaults.removePersistentDomain(forName: targetID)
    _ = preparePreferences(defaults, bundleIdentifier: "another.app", legacyIdentifier: legacyID, targetIdentifier: targetID)
    assert(!defaults.bool(forKey: preferencesMigrationKey), "Unrelated apps must not migrate")
    _ = preparePreferences(defaults, bundleIdentifier: targetID, legacyIdentifier: prefix + ".missing", targetIdentifier: targetID)
    assert(defaults.bool(forKey: preferencesMigrationKey), "First launch without legacy settings must complete")
    print("PASS: migration copies once, preserves Plus edits and legacy settings, disables upstream updates, handles fresh installs")
  }
}
