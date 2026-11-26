import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 8, track `app`, D7 + D8: exit counts and release notes.
//
// Names the builder must provide:
//
//   public struct ExitCounts: Equatable, Sendable
//       public struct Counts: Equatable, Sendable
//           public var memoryLimit, watchdog, crash, illegalInstruction, suspendedWithLockedFile,
//                      backgroundTaskTimeout, memoryPressure: Int            all 0 by default (`Counts()`)
//           public var total: Int                                            the sum of the seven
//       public var foreground: Counts, background: Counts
//       public init(json: Data)                  a MetricKit MXMetricPayload.jsonRepresentation(); never fails: bad
//                                                JSON or no applicationExitMetrics gives all zeros
//       public var hasProblem: Bool              any of the 14 counts above is more than 0
//     MetricKit key -> field:  cumulativeMemoryResourceLimitExitCount -> memoryLimit, cumulativeAppWatchdogExitCount ->
//     watchdog, cumulativeBadAccessExitCount + cumulativeAbnormalExitCount -> crash,
//     cumulativeIllegalInstructionExitCount -> illegalInstruction, cumulativeSuspendedWithLockedFileExitCount ->
//     suspendedWithLockedFile (background only), cumulativeBackgroundTaskAssertionTimeoutExitCount ->
//     backgroundTaskTimeout (background only), cumulativeMemoryPressureExitCount -> memoryPressure (background only).
//     Normal exits (cumulativeNormalAppExitCount) never count.
//
//   public enum ReleaseNotes
//       public struct Release: Equatable, Sendable { public let build: Int; version: String; date: String ("yyyy-MM-dd");
//                                                    items: [String] }
//       public static let all: [Release]                                    builds 8, 7, 6, 5, 4 in that order
//       public static func unseen(lastSeen: Int?, current: Int) -> [Release]
//       public static func notesText(build: Int) -> String?                 "- item" lines joined by "\n", or nil

// MARK: D7

final class Build8ExitCountsTests: XCTestCase {
    /// MXMetricPayload.jsonRepresentation() as iOS 26 writes it, with the sections the app does not read.
    private func payload(exits: String) -> Data {
        Data("""
        {
          "timeStampBegin": "2026-11-24 05:00:00 +0000",
          "timeStampEnd": "2026-11-25 05:00:00 +0000",
          "metaData": { "appBuildVersion": "8", "deviceType": "iPhone16,2", "osVersion": "iPhone OS 26.1 (23B85)",
                        "platformArchitecture": "arm64e", "regionFormat": "US", "bundleIdentifier": "com.hersheyg.meetspike.hr" },
          "applicationLaunchMetrics": { "histogrammedTimeToFirstDrawKey": { "histogramNumBuckets": 1 } },
          "applicationTimeMetrics": { "cumulativeForegroundTime": "1800 sec", "cumulativeBackgroundTime": "40000 sec" },
          "cpuMetrics": { "cumulativeCPUTime": "120 sec" },
          \(exits)
          "memoryMetrics": { "peakMemoryUsage": "180000 kB" }
        }
        """.utf8)
    }

    private func exits(foreground: String, background: String) -> String {
        "\"applicationExitMetrics\": { \"foregroundExitData\": { \(foreground) }, \"backgroundExitData\": { \(background) } },"
    }

    private let cleanForeground = """
    "cumulativeNormalAppExitCount": 12, "cumulativeMemoryResourceLimitExitCount": 0, "cumulativeBadAccessExitCount": 0,
    "cumulativeAbnormalExitCount": 0, "cumulativeIllegalInstructionExitCount": 0, "cumulativeAppWatchdogExitCount": 0
    """
    private let cleanBackground = """
    "cumulativeNormalAppExitCount": 30, "cumulativeMemoryResourceLimitExitCount": 0, "cumulativeCPUResourceLimitExitCount": 0,
    "cumulativeMemoryPressureExitCount": 0, "cumulativeBadAccessExitCount": 0, "cumulativeAbnormalExitCount": 0,
    "cumulativeIllegalInstructionExitCount": 0, "cumulativeAppWatchdogExitCount": 0,
    "cumulativeSuspendedWithLockedFileExitCount": 0, "cumulativeBackgroundTaskAssertionTimeoutExitCount": 0
    """

    func testACleanDayHasNoProblem() {
        let counts = ExitCounts(json: payload(exits: exits(foreground: cleanForeground, background: cleanBackground)))
        XCTAssertFalse(counts.hasProblem)
        XCTAssertEqual(counts.foreground, ExitCounts.Counts())
        XCTAssertEqual(counts.background, ExitCounts.Counts())
        XCTAssertEqual(counts.foreground.total, 0)
        XCTAssertEqual(counts.background.total, 0)
    }

    func testEachForegroundCounterIsReadOnItsOwn() {
        let table: [(String, KeyPath<ExitCounts.Counts, Int>)] = [
            ("cumulativeMemoryResourceLimitExitCount", \.memoryLimit),
            ("cumulativeAppWatchdogExitCount", \.watchdog),
            ("cumulativeBadAccessExitCount", \.crash),
            ("cumulativeAbnormalExitCount", \.crash),
            ("cumulativeIllegalInstructionExitCount", \.illegalInstruction),
        ]
        for (key, path) in table {
            let counts = ExitCounts(json: payload(exits: exits(foreground: "\"\(key)\": 3", background: "")))
            XCTAssertEqual(counts.foreground[keyPath: path], 3, key)
            XCTAssertEqual(counts.foreground.total, 3, key)
            XCTAssertEqual(counts.background, ExitCounts.Counts(), key)
            XCTAssertTrue(counts.hasProblem, key)
        }
    }

    func testEachBackgroundCounterIsReadOnItsOwn() {
        let table: [(String, KeyPath<ExitCounts.Counts, Int>)] = [
            ("cumulativeMemoryResourceLimitExitCount", \.memoryLimit),
            ("cumulativeAppWatchdogExitCount", \.watchdog),
            ("cumulativeBadAccessExitCount", \.crash),
            ("cumulativeAbnormalExitCount", \.crash),
            ("cumulativeIllegalInstructionExitCount", \.illegalInstruction),
            ("cumulativeSuspendedWithLockedFileExitCount", \.suspendedWithLockedFile),
            ("cumulativeBackgroundTaskAssertionTimeoutExitCount", \.backgroundTaskTimeout),
            ("cumulativeMemoryPressureExitCount", \.memoryPressure),
        ]
        for (key, path) in table {
            let counts = ExitCounts(json: payload(exits: exits(foreground: "", background: "\"\(key)\": 2")))
            XCTAssertEqual(counts.background[keyPath: path], 2, key)
            XCTAssertEqual(counts.background.total, 2, key)
            XCTAssertEqual(counts.foreground, ExitCounts.Counts(), key)
            XCTAssertTrue(counts.hasProblem, key)
        }
    }

    func testForegroundAndBackgroundDoNotMix() {
        let counts = ExitCounts(json: payload(exits: exits(
            foreground: "\"cumulativeAppWatchdogExitCount\": 1, \"cumulativeMemoryResourceLimitExitCount\": 4",
            background: "\"cumulativeMemoryPressureExitCount\": 5, \"cumulativeAppWatchdogExitCount\": 2"
        )))
        XCTAssertEqual(counts.foreground.watchdog, 1)
        XCTAssertEqual(counts.foreground.memoryLimit, 4)
        XCTAssertEqual(counts.foreground.memoryPressure, 0)
        XCTAssertEqual(counts.background.watchdog, 2)
        XCTAssertEqual(counts.background.memoryPressure, 5)
        XCTAssertEqual(counts.background.memoryLimit, 0)
        XCTAssertEqual(counts.foreground.total, 5)
        XCTAssertEqual(counts.background.total, 7)
    }

    func testNormalExitsAndUnlistedCountersAreNotAProblem() {
        let counts = ExitCounts(json: payload(exits: exits(
            foreground: "\"cumulativeNormalAppExitCount\": 500",
            background: "\"cumulativeNormalAppExitCount\": 900, \"cumulativeCPUResourceLimitExitCount\": 0"
        )))
        XCTAssertFalse(counts.hasProblem)
        XCTAssertEqual(counts.foreground.total + counts.background.total, 0)
    }

    func testOneProblemInOneSideIsEnough() {
        XCTAssertTrue(ExitCounts(json: payload(exits: exits(foreground: cleanForeground, background: cleanBackground
            .replacingOccurrences(of: "\"cumulativeBackgroundTaskAssertionTimeoutExitCount\": 0", with: "\"cumulativeBackgroundTaskAssertionTimeoutExitCount\": 1")))).hasProblem)
        XCTAssertTrue(ExitCounts(json: payload(exits: exits(foreground: cleanForeground
            .replacingOccurrences(of: "\"cumulativeAbnormalExitCount\": 0", with: "\"cumulativeAbnormalExitCount\": 1"), background: cleanBackground))).hasProblem)
    }

    func testMissingSectionsAndMissingKeysAreZero() {
        XCTAssertFalse(ExitCounts(json: payload(exits: "")).hasProblem)
        XCTAssertFalse(ExitCounts(json: payload(exits: "\"applicationExitMetrics\": {},")).hasProblem)
        let onlyForeground = ExitCounts(json: payload(exits: "\"applicationExitMetrics\": { \"foregroundExitData\": { \"cumulativeAppWatchdogExitCount\": 1 } },"))
        XCTAssertEqual(onlyForeground.foreground.watchdog, 1)
        XCTAssertEqual(onlyForeground.background, ExitCounts.Counts())
        XCTAssertTrue(onlyForeground.hasProblem)
    }

    func testGarbageGivesZerosAndNeverFails() {
        for text in ["", "nope", "{", "[]", "null", "42", "{\"applicationExitMetrics\": 5}",
                     "{\"applicationExitMetrics\": {\"foregroundExitData\": \"x\", \"backgroundExitData\": []}}"] {
            let counts = ExitCounts(json: Data(text.utf8))
            XCTAssertFalse(counts.hasProblem, text)
            XCTAssertEqual(counts.foreground, ExitCounts.Counts(), text)
            XCTAssertEqual(counts.background, ExitCounts.Counts(), text)
        }
        XCTAssertFalse(ExitCounts(json: Data([0xFF, 0x00])).hasProblem)
    }

    func testOddNumbersDoNotCrashOrCountAsProblems() {
        for value in ["-3", "0.0", "\"4\"", "null", "true", "[]", "{}"] {
            let counts = ExitCounts(json: payload(exits: exits(foreground: "\"cumulativeAppWatchdogExitCount\": \(value)", background: "")))
            XCTAssertGreaterThanOrEqual(counts.foreground.watchdog, 0, value)
        }
        XCTAssertFalse(ExitCounts(json: payload(exits: exits(foreground: "\"cumulativeAppWatchdogExitCount\": -3", background: ""))).hasProblem)
        XCTAssertEqual(ExitCounts(json: payload(exits: exits(foreground: "\"cumulativeAppWatchdogExitCount\": 2.0", background: ""))).foreground.watchdog, 2)
    }

    func testCountsStartAtZero() {
        let counts = ExitCounts.Counts()
        for value in [counts.memoryLimit, counts.watchdog, counts.crash, counts.illegalInstruction, counts.suspendedWithLockedFile,
                      counts.backgroundTaskTimeout, counts.memoryPressure, counts.total] {
            XCTAssertEqual(value, 0)
        }
    }
}

// MARK: D8

final class Build8ReleaseNotesTests: XCTestCase {
    func testTheFiveReleasesNewestFirst() {
        let builds = ReleaseNotes.all.map(\.build)
        XCTAssertEqual(builds.filter { $0 <= 8 }, [8, 7, 6, 5, 4])
        XCTAssertEqual(builds, builds.sorted(by: >), "newest first")
    }

    func testVersions() {
        let versions = Dictionary(uniqueKeysWithValues: ReleaseNotes.all.map { ($0.build, $0.version) })
        XCTAssertEqual(versions[8], "1.1")
        for build in 4...7 { XCTAssertEqual(versions[build], "1.0", "build \(build)") }
    }

    func testDatesAreRealDaysAndNeverGoUpAsBuildsGoDown() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        var previous: Date?
        for release in ReleaseNotes.all {
            XCTAssertNotNil(release.date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression), release.date)
            let day = try XCTUnwrap(formatter.date(from: release.date), "build \(release.build): \(release.date)")
            XCTAssertEqual(formatter.string(from: day), release.date, "a real calendar day")
            if let previous { XCTAssertLessThanOrEqual(day, previous, "build \(release.build) is older than the one above it") }
            previous = day
        }
    }

    func testEveryItemIsShortPlainAndNotBlank() {
        for release in ReleaseNotes.all {
            XCTAssertFalse(release.items.isEmpty, "build \(release.build)")
            for item in release.items {
                XCTAssertFalse(item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "build \(release.build)")
                XCTAssertEqual(item, item.trimmingCharacters(in: .whitespacesAndNewlines), "no stray spaces: \(item)")
                XCTAssertLessThan(item.count, 120, item)
                XCTAssertFalse(item.contains("\u{2014}"), "no em dash: \(item)")
                XCTAssertFalse(item.contains("\n"), "one line per item: \(item)")
            }
        }
    }

    func testBuild8TellsAboutTheNewThings() {
        let text = (ReleaseNotes.all.first { $0.build == 8 }?.items ?? []).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("crash"), text)
        XCTAssertTrue(text.contains("dark"), text)
    }

    // MARK: unseen

    func testAFreshInstallSeesNothing() {
        XCTAssertEqual(ReleaseNotes.unseen(lastSeen: nil, current: 8), [])
        XCTAssertEqual(ReleaseNotes.unseen(lastSeen: nil, current: 4), [])
        XCTAssertEqual(ReleaseNotes.unseen(lastSeen: nil, current: 100), [])
    }

    func testUnseenAreTheReleasesAfterTheLastSeenUpToCurrentNewestFirst() {
        func builds(_ lastSeen: Int?, _ current: Int) -> [Int] { ReleaseNotes.unseen(lastSeen: lastSeen, current: current).map(\.build) }
        XCTAssertEqual(builds(7, 8), [8])
        XCTAssertEqual(builds(5, 8), [8, 7, 6])
        XCTAssertEqual(builds(4, 8), [8, 7, 6, 5])
        XCTAssertEqual(builds(3, 8), [8, 7, 6, 5, 4])
        XCTAssertEqual(builds(0, 8), [8, 7, 6, 5, 4])
        XCTAssertEqual(builds(-5, 8), [8, 7, 6, 5, 4])
        XCTAssertEqual(builds(4, 6), [6, 5])
        XCTAssertEqual(builds(5, 6), [6])
    }

    func testNothingNewMeansNothing() {
        func builds(_ lastSeen: Int?, _ current: Int) -> [Int] { ReleaseNotes.unseen(lastSeen: lastSeen, current: current).map(\.build) }
        XCTAssertEqual(builds(8, 8), [])
        XCTAssertEqual(builds(9, 8), [], "a downgrade shows nothing")
        XCTAssertEqual(builds(100, 8), [])
        XCTAssertEqual(builds(7, 7), [])
        XCTAssertEqual(builds(3, 3), [])
        XCTAssertEqual(builds(2, 3), [], "builds before the first note have no note")
    }

    func testABuildAheadOfTheNotesShowsWhatExists() {
        // The app on a build with no note written yet: show the older unseen ones, never crash.
        let newest = ReleaseNotes.all.first?.build ?? 0
        XCTAssertEqual(ReleaseNotes.unseen(lastSeen: 6, current: newest + 1).map(\.build), ReleaseNotes.all.map(\.build).filter { $0 > 6 })
        XCTAssertEqual(ReleaseNotes.unseen(lastSeen: newest, current: newest + 1).map(\.build), [])
    }

    func testUnseenReleasesAreTheRealOnes() {
        let upTo8 = ReleaseNotes.all.filter { $0.build <= 8 }
        XCTAssertEqual(ReleaseNotes.unseen(lastSeen: 3, current: 8), upTo8)
        XCTAssertEqual(ReleaseNotes.unseen(lastSeen: 6, current: 8), Array(upTo8.prefix(2)))
    }

    // MARK: notesText

    func testNotesTextIsDashBulletsOneItemPerLine() throws {
        for release in ReleaseNotes.all {
            let text = try XCTUnwrap(ReleaseNotes.notesText(build: release.build), "build \(release.build)")
            XCTAssertEqual(text, release.items.map { "- \($0)" }.joined(separator: "\n"))
            XCTAssertFalse(text.hasSuffix("\n"))
            XCTAssertFalse(text.contains("\u{2014}"))
            XCTAssertLessThan(text.count, 4000, "TestFlight What to Test is capped at 4000 characters")
        }
    }

    func testNotesTextIsNilForABuildWithNoNote() {
        let beyond = (ReleaseNotes.all.first?.build ?? 0) + 1
        for build in [-1, 0, 1, 3, beyond, 99] { XCTAssertNil(ReleaseNotes.notesText(build: build), "build \(build)") }
    }

    func testReleaseIsSendableAndEquatable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }
        let release = requireSendable(ReleaseNotes.all[0])
        XCTAssertEqual(release, ReleaseNotes.all[0])
        XCTAssertNotEqual(release, ReleaseNotes.all[1])
    }
}
