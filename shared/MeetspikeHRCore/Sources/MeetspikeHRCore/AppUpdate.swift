import Foundation

/// "Update available" for the iPhone TestFlight app. The release script tells
/// the Worker the newest processed build; the app compares it with its own.
public enum AppUpdate {
    /// Opens Meetspike in the TestFlight app.
    public static let testFlightURL = URL(string: "itms-beta://beta.itunes.apple.com/v1/app/6838520447")!
    /// Fallback when the TestFlight app isn't installed: the App Store page for TestFlight.
    public static let testFlightInstallURL = URL(string: "https://apps.apple.com/app/testflight/id899247664")!

    /// The newer build to offer, or nil when this build is current or either number is unknown.
    public static func availableBuild(current: String?, latest: Int?) -> Int? {
        guard let latest, let current = current.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
              latest > current else { return nil }
        return latest
    }
}

/// GET /api/whoop-web/app/ios.
public struct LatestBuildReply: Decodable, Sendable {
    public let ok: Bool
    public let build: Int?
}
