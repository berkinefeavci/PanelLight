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

// Every link the app opens is a constant HTTPS URL into the project's own repository.
enum SupportLinks {
    private static let repository = "https://github.com/berkinefeavci/PanelLight"
    static let reportBug = URL(string: repository + "/issues/new?template=bug_report.yml")!
    static let suggestFeature = URL(string: repository + "/issues/new?template=feature_request.yml")!
    static let latestRelease = URL(string: repository + "/releases/latest")!
    static var all: [URL] { [reportBug, suggestFeature, latestRelease] }
}
