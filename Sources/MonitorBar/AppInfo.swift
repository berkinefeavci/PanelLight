import Foundation

enum AppInfo {
    static var versionText: String? {
        versionText(short: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    // "Version 0.2.0 (11)"; nil when the binary runs outside an app bundle (swift run, tests).
    static func versionText(short: String?, build: String?) -> String? {
        guard let short, !short.isEmpty else { return nil }
        guard let build, !build.isEmpty else { return String(localized: "Version \(short)") }
        return String(localized: "Version \(short) (\(build))")
    }
}
