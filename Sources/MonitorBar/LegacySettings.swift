import Foundation

// Preferences of features PanelLight no longer has: the timed day/night brightness of 0.1.x.
// Removed once so old installs do not keep dead values in their settings.
enum LegacySettings {
    static let obsoleteKeys = ["scheduleEnabled", "nightStart", "nightEnd", "nightBrightness", "dayBrightness"]

    static func removeObsoleteKeys(from defaults: UserDefaults = .standard) {
        for key in obsoleteKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }
}
