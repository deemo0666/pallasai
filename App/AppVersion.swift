import Foundation

enum AppVersion {
    /// `MARKETING_VERSION`.
    static var marketing: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0" }
    static var build: String? { (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    /// `0.1.0 (1)`.
    static var label: String { build.map { marketing + " (" + $0 + ")" } ?? marketing }
}
