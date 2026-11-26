import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 8, track `app`, D2 + D3: the scrubber and the signature. Helpers (B8) are in Build8DiagnosticReportTests.swift.
//
// Names the builder must provide:
//
//   public enum DiagnosticScrubber { public static func scrub(_ data: Data) -> DiagnosticValue }
//       Input is ONE MetricKit diagnostic as MXCrashDiagnostic / MXHangDiagnostic / MXCPUExceptionDiagnostic /
//       MXDiskWriteExceptionDiagnostic.jsonRepresentation() returns it (keys callStackTree + diagnosticMetaData).
//       Walks the JSON; at every depth keeps a key only if it is on the server allowlist (spec8.md, Server track),
//       and under it keeps only numbers, booleans, strings and containers of those (null dropped). Dropped keys take
//       their whole subtree with them. Beyond the key list the spec's server limits apply on the phone too, so a
//       huge hang can never make the body a 413 that is rejected and lost: strings cut to 500 characters, container
//       depth at most 300 (objects and arrays both count, the server's number; deeper is dropped, not an error), and
//       the encoded result at most
//       200,000 bytes (the server takes 256 KB), whatever the input. Bad or non-object JSON gives `.object([:])`.
//       It never crashes, including on 100,000 levels of nesting. (Fix pass 2, F2: it used to be `{}` because
//       JSONSerialization refuses more than 512 levels; now an iterative scan cuts everything deeper than 300 first,
//       so a valid object keeps its shallow part. Broken JSON and a non-object root are still `{}`.)
//
//   public enum DiagnosticSignature { public static func make(kind: DiagnosticReport.Kind, report: DiagnosticValue) -> String? }
//       `report` is the scrubbed value. Frames: among report.callStackTree.callStacks pick the stack with
//       threadAttributed == true (first such; if none is attributed, the first stack). In that stack walk from the
//       callStackRootFrames entry with the highest sampleCount (first on a tie) down through the subFrames entry
//       with the highest sampleCount (first on a tie) to the deepest frame. Which end is the top of the stack
//       depends on callStackTree.callStackPerThread (fix pass 2, F3): when it is false or missing the deepest frame
//       is the top, so the 3 frames used are deepest, its caller, its caller's caller (fewer if the chain is
//       shorter); when it is true the ROOT frame is the newest ("crash site first"), so the 3 frames used are the
//       first 3 of the chain from the root.
//       A frame is "<binaryName>+<offsetIntoBinaryTextSegment>" (offset as a whole number, no ".0"); a frame without
//       binaryName or offset is skipped. Frames join with " < ".
//       Prefix: the present values of diagnosticMetaData.exceptionType, .signal, .terminationReason (in that order,
//       numbers as whole numbers) joined with "/", then " | " and the frames. Prefix only when there are no frames:
//       just the prefix. Frames only when there is no prefix: just the frames. Nothing at all: nil.
//       Never longer than 200 characters (cut, not dropped).

// MARK: Fixtures. Shaped like what MetricKit hands the app on iOS 26: the key names, the nesting, the personal fields.

enum B8Fixtures {
    static let crashPersonal = [
        "Dentist with Dana Cole", "Dana Cole", "dana.cole@example.com", "com.hersheyg.meetspike.hr", "Ada's iPhone",
        "Bytes before following region: 4306468864",
    ]

    /// MXCrashDiagnostic.jsonRepresentation(): an assertion failure with an NSException-style reason that quotes a
    /// meeting title, plus the per-process fields MetricKit adds.
    static let crash = """
    {
      "version": "1.0.0",
      "callStackTree": {
        "callStackPerThread": true,
        "callStacks": [
          {
            "threadAttributed": false,
            "callStackRootFrames": [
              { "binaryUUID": "11111111-AAAA-4AAA-8AAA-000000000001", "offsetIntoBinaryTextSegment": 2048,
                "sampleCount": 1, "binaryName": "libsystem_pthread.dylib", "address": 6781012000 }
            ]
          },
          {
            "threadAttributed": true,
            "callStackRootFrames": [
              { "binaryUUID": "22222222-BBBB-4BBB-8BBB-000000000002", "offsetIntoBinaryTextSegment": 86020,
                "sampleCount": 1, "binaryName": "dyld", "address": 6781012996,
                "subFrames": [
                  { "binaryUUID": "33333333-CCCC-4CCC-8CCC-000000000003", "offsetIntoBinaryTextSegment": 412224,
                    "sampleCount": 1, "binaryName": "MeetspikeHR", "address": 4300000000,
                    "subFrames": [
                      { "binaryUUID": "44444444-DDDD-4DDD-8DDD-000000000004", "offsetIntoBinaryTextSegment": 5532160,
                        "sampleCount": 1, "binaryName": "SwiftUI", "address": 6500000000,
                        "subFrames": [
                          { "binaryUUID": "33333333-CCCC-4CCC-8CCC-000000000003", "offsetIntoBinaryTextSegment": 1048576,
                            "sampleCount": 1, "binaryName": "MeetspikeHR", "address": 4300636352,
                            "subFrames": [
                              { "binaryUUID": "55555555-EEEE-4EEE-8EEE-000000000005", "offsetIntoBinaryTextSegment": 2900352,
                                "sampleCount": 1, "binaryName": "libswiftCore.dylib", "address": 6600000000 }
                            ] }
                        ] }
                    ] }
                ] }
            ]
          }
        ]
      },
      "diagnosticMetaData": {
        "appBuildVersion": "8",
        "appVersion": "1.1",
        "bundleIdentifier": "com.hersheyg.meetspike.hr",
        "deviceType": "iPhone16,2",
        "exceptionCode": 1,
        "exceptionType": 6,
        "isTestFlightApp": true,
        "lowPowerModeEnabled": false,
        "osVersion": "iPhone OS 26.1 (23B85)",
        "pid": 812,
        "platformArchitecture": "arm64e",
        "regionFormat": "US",
        "signal": 5,
        "terminationReason": "Namespace SIGNAL, Code 5 Trace/BPT trap: 5",
        "virtualMemoryRegionInfo": "0 is not in any region. Bytes before following region: 4306468864",
        "exceptionReason": {
          "composedMessage": "Meeting 'Dentist with Dana Cole' not found for dana.cole@example.com",
          "arguments": ["Dana Cole", "dana.cole@example.com"],
          "className": "NSException",
          "exceptionName": "NSInvalidArgumentException",
          "formatString": "Meeting '%@' not found for %@"
        }
      }
    }
    """

    /// What the scrubber must give for `crash`: the same tree with the personal and per-process keys gone.
    static let crashScrubbed = """
    {
      "callStackTree": {
        "callStackPerThread": true,
        "callStacks": [
          {
            "threadAttributed": false,
            "callStackRootFrames": [
              { "binaryUUID": "11111111-AAAA-4AAA-8AAA-000000000001", "offsetIntoBinaryTextSegment": 2048,
                "sampleCount": 1, "binaryName": "libsystem_pthread.dylib", "address": 6781012000 }
            ]
          },
          {
            "threadAttributed": true,
            "callStackRootFrames": [
              { "binaryUUID": "22222222-BBBB-4BBB-8BBB-000000000002", "offsetIntoBinaryTextSegment": 86020,
                "sampleCount": 1, "binaryName": "dyld", "address": 6781012996,
                "subFrames": [
                  { "binaryUUID": "33333333-CCCC-4CCC-8CCC-000000000003", "offsetIntoBinaryTextSegment": 412224,
                    "sampleCount": 1, "binaryName": "MeetspikeHR", "address": 4300000000,
                    "subFrames": [
                      { "binaryUUID": "44444444-DDDD-4DDD-8DDD-000000000004", "offsetIntoBinaryTextSegment": 5532160,
                        "sampleCount": 1, "binaryName": "SwiftUI", "address": 6500000000,
                        "subFrames": [
                          { "binaryUUID": "33333333-CCCC-4CCC-8CCC-000000000003", "offsetIntoBinaryTextSegment": 1048576,
                            "sampleCount": 1, "binaryName": "MeetspikeHR", "address": 4300636352,
                            "subFrames": [
                              { "binaryUUID": "55555555-EEEE-4EEE-8EEE-000000000005", "offsetIntoBinaryTextSegment": 2900352,
                                "sampleCount": 1, "binaryName": "libswiftCore.dylib", "address": 6600000000 }
                            ] }
                        ] }
                    ] }
                ] }
            ]
          }
        ]
      },
      "diagnosticMetaData": {
        "appBuildVersion": "8",
        "appVersion": "1.1",
        "deviceType": "iPhone16,2",
        "exceptionCode": 1,
        "exceptionType": 6,
        "osVersion": "iPhone OS 26.1 (23B85)",
        "platformArchitecture": "arm64e",
        "signal": 5,
        "terminationReason": "Namespace SIGNAL, Code 5 Trace/BPT trap: 5"
      }
    }
    """

    /// MXHangDiagnostic.jsonRepresentation(): one main-thread tree with branches weighted by sampleCount.
    static let hang = """
    {
      "version": "1.0.0",
      "callStackTree": {
        "callStackPerThread": false,
        "callStacks": [
          {
            "threadAttributed": true,
            "callStackRootFrames": [
              { "binaryUUID": "33333333-CCCC-4CCC-8CCC-000000000003", "offsetIntoBinaryTextSegment": 412224,
                "sampleCount": 20, "binaryName": "MeetspikeHR", "address": 4300000000,
                "subFrames": [
                  { "binaryUUID": "66666666-FFFF-4FFF-8FFF-000000000006", "offsetIntoBinaryTextSegment": 100,
                    "sampleCount": 3, "binaryName": "UIKitCore", "address": 6000000100,
                    "subFrames": [
                      { "binaryUUID": "77777777-0000-4000-8000-000000000007", "offsetIntoBinaryTextSegment": 11,
                        "sampleCount": 3, "binaryName": "QuartzCore", "address": 6100000011 }
                    ] },
                  { "binaryUUID": "44444444-DDDD-4DDD-8DDD-000000000004", "offsetIntoBinaryTextSegment": 5532160,
                    "sampleCount": 17, "binaryName": "SwiftUI", "address": 6500000000,
                    "subFrames": [
                      { "binaryUUID": "33333333-CCCC-4CCC-8CCC-000000000003", "offsetIntoBinaryTextSegment": 2097152,
                        "sampleCount": 14, "binaryName": "MeetspikeHR", "address": 4301000000,
                        "subFrames": [
                          { "binaryUUID": "88888888-1111-4111-8111-000000000008", "offsetIntoBinaryTextSegment": 777,
                            "sampleCount": 14, "binaryName": "Foundation", "address": 6200000777 }
                        ] },
                      { "binaryUUID": "99999999-2222-4222-8222-000000000009", "offsetIntoBinaryTextSegment": 5,
                        "sampleCount": 3, "binaryName": "libsystem_kernel.dylib", "address": 6300000005 }
                    ] }
                ] }
            ]
          }
        ]
      },
      "diagnosticMetaData": {
        "appBuildVersion": "8",
        "appVersion": "1.1",
        "bundleIdentifier": "com.hersheyg.meetspike.hr",
        "deviceType": "iPhone16,2",
        "hangDuration": "2.51 sec",
        "osVersion": "iPhone OS 26.1 (23B85)",
        "pid": 812,
        "platformArchitecture": "arm64e",
        "regionFormat": "US"
      }
    }
    """

    static let cpu = """
    {
      "version": "1.0.0",
      "callStackTree": { "callStackPerThread": true, "callStacks": [ { "threadAttributed": true, "callStackRootFrames": [
        { "binaryUUID": "33333333-CCCC-4CCC-8CCC-000000000003", "offsetIntoBinaryTextSegment": 4096, "sampleCount": 9,
          "binaryName": "MeetspikeHR", "address": 4300004096 } ] } ] },
      "diagnosticMetaData": {
        "appBuildVersion": "8", "appVersion": "1.1", "deviceType": "iPhone16,2", "osVersion": "iPhone OS 26.1 (23B85)",
        "platformArchitecture": "arm64e", "regionFormat": "US", "totalCPUTime": "197.33 sec", "totalSampledTime": "216 sec"
      }
    }
    """

    static let disk = """
    {
      "version": "1.0.0",
      "callStackTree": { "callStackPerThread": false, "callStacks": [ { "threadAttributed": true, "callStackRootFrames": [
        { "binaryUUID": "33333333-CCCC-4CCC-8CCC-000000000003", "offsetIntoBinaryTextSegment": 8192, "sampleCount": 1,
          "binaryName": "MeetspikeHR", "address": 4300008192 } ] } ] },
      "diagnosticMetaData": {
        "appBuildVersion": "8", "appVersion": "1.1", "deviceType": "iPhone16,2", "osVersion": "iPhone OS 26.1 (23B85)",
        "platformArchitecture": "arm64e", "regionFormat": "US", "writesCaused": "1073741824 bytes"
      }
    }
    """

    /// The whole MXDiagnosticPayload.jsonRepresentation(): the diagnostics sit in arrays under keys that are not on
    /// the allowlist, so a payload fed in whole must not leak. (The service feeds each diagnostic on its own.)
    static var payload: String {
        """
        {
          "timeStampBegin": "2026-11-24 05:00:00 +0000",
          "timeStampEnd": "2026-11-25 05:00:00 +0000",
          "crashDiagnostics": [\(crash)],
          "hangDiagnostics": [\(hang)]
        }
        """
    }
}

// MARK: D2

final class Build8ScrubberTests: XCTestCase {
    private func scrub(_ json: String) -> DiagnosticValue { DiagnosticScrubber.scrub(Data(json.utf8)) }

    func testCrashKeepsTheCallStackTreeAndTheAllowedMetadataExactly() {
        B8.assertEqual(scrub(B8Fixtures.crash), B8Fixtures.crashScrubbed)
    }

    func testCrashDropsEveryPersonalAndPerProcessField() throws {
        let value = scrub(B8Fixtures.crash)
        let text = try B8.text(value)
        for personal in B8Fixtures.crashPersonal {
            XCTAssertFalse(text.contains(personal), "leaked \(personal)")
        }
        for key in ["exceptionReason", "composedMessage", "arguments", "className", "exceptionName", "formatString",
                    "virtualMemoryRegionInfo", "regionFormat", "bundleIdentifier", "pid", "isTestFlightApp",
                    "lowPowerModeEnabled", "version"] {
            XCTAssertFalse(text.contains("\"\(key)\""), "kept \(key)")
        }
        XCTAssertFalse(text.contains("Dana"), text)
        XCTAssertFalse(text.contains("@example.com"), text)
    }

    func testHangKeepsTheDurationAndTheBranchedTree() {
        let value = scrub(B8Fixtures.hang)
        guard case .object(let root) = value, case .object(let meta)? = root["diagnosticMetaData"] else {
            return XCTFail("no diagnosticMetaData in \(value)")
        }
        XCTAssertEqual(meta["hangDuration"], .string("2.51 sec"))
        XCTAssertEqual(Set(meta.keys), ["appBuildVersion", "appVersion", "deviceType", "hangDuration", "osVersion", "platformArchitecture"])
        XCTAssertNotNil(root["callStackTree"])
        XCTAssertEqual(Set(root.keys), ["callStackTree", "diagnosticMetaData"])
        XCTAssertEqual(B8.strings(value).filter { $0 == "libsystem_kernel.dylib" || $0 == "QuartzCore" }.count, 2,
                       "all branches stay, not just the heavy one")
    }

    func testCPUAndDiskDiagnosticsKeepTheirOwnMetadata() throws {
        let cpu = try XCTUnwrap(object(scrub(B8Fixtures.cpu), "diagnosticMetaData"))
        XCTAssertEqual(cpu["totalCPUTime"], .string("197.33 sec"))
        XCTAssertEqual(cpu["totalSampledTime"], .string("216 sec"))
        XCTAssertNil(cpu["regionFormat"])
        let disk = try XCTUnwrap(object(scrub(B8Fixtures.disk), "diagnosticMetaData"))
        XCTAssertEqual(disk["writesCaused"], .string("1073741824 bytes"))
        XCTAssertNil(disk["regionFormat"])
    }

    private func object(_ value: DiagnosticValue, _ key: String) -> [String: DiagnosticValue]? {
        guard case .object(let root) = value, case .object(let inner)? = root[key] else { return nil }
        return inner
    }

    func testTheWholeAllowlistIsKept() {
        let keys = ["callStackTree", "callStacks", "callStackPerThread", "threadAttributed", "callStackRootFrames",
                    "subFrames", "binaryUUID", "binaryName", "offsetIntoBinaryTextSegment", "address", "sampleCount",
                    "diagnosticMetaData", "appBuildVersion", "appVersion", "osVersion", "deviceType",
                    "platformArchitecture", "exceptionType", "exceptionCode", "signal", "terminationReason",
                    "hangDuration", "totalCPUTime", "totalSampledTime", "writesCaused", "message", "code", "path"]
        // Each key on its own at the top level with a leaf of each type: kept as is.
        for key in keys {
            for leaf in ["7", "true", "\"text\""] {
                B8.assertEqual(scrub("{\"\(key)\": \(leaf)}"), "{\"\(key)\": \(leaf)}")
            }
        }
    }

    func testKeysOffTheAllowlistAreDroppedAtEveryDepthWithTheirSubtree() {
        let json = """
        {"callStackTree":{"callStacks":[{"threadAttributed":true,"secret":"dana@example.com","extra":{"sampleCount":5},
          "callStackRootFrames":[{"binaryName":"A","offsetIntoBinaryTextSegment":1,"title":"Dentist","unknown":[1,2],
            "subFrames":[{"binaryName":"B","offsetIntoBinaryTextSegment":2,"note":"x"}]}]}],"name":"Dana"},
         "diagnosticMetaData":{"appVersion":"1.1","regionFormat":"US","email":"dana@example.com"},"title":"Dentist"}
        """
        B8.assertEqual(scrub(json), """
        {"callStackTree":{"callStacks":[{"threadAttributed":true,
          "callStackRootFrames":[{"binaryName":"A","offsetIntoBinaryTextSegment":1,
            "subFrames":[{"binaryName":"B","offsetIntoBinaryTextSegment":2}]}]}]},
         "diagnosticMetaData":{"appVersion":"1.1"}}
        """)
    }

    func testAKeyIsMatchedExactlyNotByCaseOrPrefix() {
        B8.assertEqual(scrub("{\"Signal\":1,\"signals\":2,\"callstacktree\":{},\"signal \":3,\"Address\":4}"), "{}")
    }

    func testNullsAreDroppedAndOnlyScalarTypesSurvive() {
        B8.assertEqual(scrub("{\"signal\":null,\"exceptionCode\":3,\"message\":null,\"code\":false}"),
                       "{\"exceptionCode\":3,\"code\":false}")
    }

    func testPayloadFedWholeLeaksNothing() throws {
        let text = try B8.text(scrub(B8Fixtures.payload))
        for personal in B8Fixtures.crashPersonal { XCTAssertFalse(text.contains(personal), "leaked \(personal)") }
        XCTAssertFalse(text.contains("crashDiagnostics"), text)
        XCTAssertFalse(text.contains("timeStamp"), text)
    }

    func testBadInputGivesAnEmptyObject() {
        let junk = ["", "not json", "{", "[1,2", "null", "42", "\"text\"", "[]", "[{\"signal\":1}]", "{\"signal\":}", "\u{0}", "{}"]
        for text in junk { XCTAssertEqual(scrub(text), .object([:]), text) }
        XCTAssertEqual(DiagnosticScrubber.scrub(Data([0xFF, 0xFE, 0x00, 0x80])), .object([:]))
        XCTAssertEqual(DiagnosticScrubber.scrub(Data()), .object([:]))
    }

    func testStringsAreCutAt500Characters() throws {
        let long = String(repeating: "x", count: 900)
        let value = scrub("{\"diagnosticMetaData\":{\"terminationReason\":\"\(long)\",\"appVersion\":\"1.1\"}}")
        let meta = try XCTUnwrap(object(value, "diagnosticMetaData"))
        XCTAssertEqual(meta["terminationReason"], .string(String(repeating: "x", count: 500)))
        XCTAssertEqual(meta["appVersion"], .string("1.1"))
        // Exactly 500 stays whole.
        let exact = String(repeating: "y", count: 500)
        B8.assertEqual(scrub("{\"message\":\"\(exact)\"}"), "{\"message\":\"\(exact)\"}")
    }

    /// `levels` + 1 frames nested through subFrames, wrapped like MetricKit does. Container depth is 2 * levels + 6
    /// (root, callStackTree, callStacks, one stack, callStackRootFrames, then an object and an array per level).
    private func chain(levels: Int) -> String {
        var json = "{\"binaryName\":\"leaf\",\"offsetIntoBinaryTextSegment\":0}"
        for level in (0..<levels).reversed() {
            json = "{\"binaryName\":\"f\(level)\",\"offsetIntoBinaryTextSegment\":\(level),\"subFrames\":[\(json)]}"
        }
        return "{\"callStackTree\":{\"callStacks\":[{\"threadAttributed\":true,\"callStackRootFrames\":[\(json)]}]}}"
    }

    func testAHundredFrameStackSurvivesWhole() throws {
        let json = chain(levels: 99)   // 100 frames, 204 levels of objects and arrays
        B8.assertEqual(scrub(json), json)
        XCTAssertEqual(B8.depth(scrub(json)), 204)
    }

    func testStacksUpToTheLimitSurviveWhole() {
        for levels in [1, 20, 120, 147] {   // 147 levels is 300 containers exactly
            let json = chain(levels: levels)
            B8.assertEqual(scrub(json), json)
        }
    }

    func testNestingPastThreeHundredIsDroppedNotACrash() {
        for levels in [148, 200, 240] {   // 2 * 240 + 6 = 486 containers, still inside what JSONSerialization parses (512)
            let value = scrub(chain(levels: levels))
            XCTAssertLessThanOrEqual(B8.depth(value), 301, "\(levels) levels")
            XCTAssertGreaterThanOrEqual(B8.depth(value), 295, "\(levels) levels: what is inside the limit stays")
            XCTAssertNotEqual(value, .object([:]))
        }
    }

    func testAbsurdNestingBeyondTheJSONParserNeverCrashesAndAnArrayRootIsAnEmptyObject() {
        let levels = 100_000
        let json = String(repeating: "[", count: levels) + String(repeating: "]", count: levels)
        XCTAssertEqual(scrub(json), .object([:]))
        // Valid JSON this deep is no longer `{}` (fix pass 2, F2: the scrub survives any depth, deeper than 300 is cut).
        // See Build8Fix2ScrubDepthTests.testAHundredThousandLevelsOfObjectsNowKeepTheShallowPart for what it gives.
        let objects = String(repeating: "{\"subFrames\":", count: levels) + "1" + String(repeating: "}", count: levels)
        XCTAssertNotEqual(scrub(objects), .object([:]))
        XCTAssertLessThanOrEqual(B8.depth(scrub(objects)), 301)
    }

    func testAHugeTreeStaysUnderTheServerBodyLimit() throws {
        // A hang with 6,000 sibling frames, each as realistic as the fixtures.
        let frame = """
        {"binaryUUID":"33333333-CCCC-4CCC-8CCC-000000000003","offsetIntoBinaryTextSegment":2097152,"sampleCount":14,
         "binaryName":"MeetspikeHR","address":4301000000}
        """
        let frames = Array(repeating: frame, count: 6000).joined(separator: ",")
        let value = scrub("{\"callStackTree\":{\"callStacks\":[{\"threadAttributed\":true,\"callStackRootFrames\":[\(frames)]}]},"
                          + "\"diagnosticMetaData\":{\"appVersion\":\"1.1\"}}")
        XCTAssertLessThanOrEqual(B8.nodeCount(value), 20_000)
        let wire = try JSONEncoder().encode(B8.report(1, kind: .hang).with(report: value))
        XCTAssertLessThanOrEqual(wire.count, 200_000, "the server answers 413 over 256 KB and the phone drops a 413")
        // What it keeps is still a tree, not an empty object.
        XCTAssertNotNil(object(value, "callStackTree"))
    }

    func testAWideObjectIsNotAnEmptyResult() throws {
        let wide = (0..<30_000).map { "\"k\($0)\":\($0)" }.joined(separator: ",")
        let value = scrub("{\"signal\":11,\"unknown\":{\(wide)}}")
        B8.assertEqual(value, "{\"signal\":11}")
    }

    func testSurrogatePairsAndOddTextSurvive() throws {
        let value = scrub("{\"terminationReason\":\"Crash \\ud83d\\ude00 \\u00e9\\n\\t\\\"quoted\\\"\"}")
        guard case .object(let root) = value, case .string(let reason)? = root["terminationReason"] else {
            return XCTFail("\(value)")
        }
        XCTAssertEqual(reason, "Crash \u{1F600} \u{E9}\n\t\"quoted\"")
    }
}

extension DiagnosticReport {
    func with(report: DiagnosticValue) -> DiagnosticReport {
        var copy = self
        copy.report = report
        return copy
    }
}

// MARK: D3

final class Build8SignatureTests: XCTestCase {
    private func signature(_ json: String, kind: DiagnosticReport.Kind = .crash) -> String? {
        DiagnosticSignature.make(kind: kind, report: DiagnosticScrubber.scrub(Data(json.utf8)))
    }

    func testCrashSignatureHasThePrefixAndTheFirstThreeFramesFromTheRootCrashSiteFirst() {
        // The fixture is a per-thread tree (callStackPerThread: true), whose root frame is the newest: the first three
        // frames from the root, not the deepest three. (Fix pass 2, F3. This used to pin the deepest-first order.)
        XCTAssertEqual(
            signature(B8Fixtures.crash),
            "6/5/Namespace SIGNAL, Code 5 Trace/BPT trap: 5 | dyld+86020 < MeetspikeHR+412224 < SwiftUI+5532160"
        )
    }

    func testTheSameCrashWithPerThreadFalseKeepsTheDeepestFirstOrder() {
        // callStackPerThread false (or missing) is the old behaviour: the deepest frame is the top of the stack.
        let notPerThread = B8Fixtures.crash.replacingOccurrences(of: "\"callStackPerThread\": true", with: "\"callStackPerThread\": false")
        XCTAssertNotEqual(notPerThread, B8Fixtures.crash)
        XCTAssertEqual(
            signature(notPerThread),
            "6/5/Namespace SIGNAL, Code 5 Trace/BPT trap: 5 | libswiftCore.dylib+2900352 < MeetspikeHR+1048576 < SwiftUI+5532160"
        )
        let missing = B8Fixtures.crash.replacingOccurrences(of: "\"callStackPerThread\": true,", with: "")
        XCTAssertNotEqual(missing, B8Fixtures.crash)
        XCTAssertEqual(
            signature(missing),
            "6/5/Namespace SIGNAL, Code 5 Trace/BPT trap: 5 | libswiftCore.dylib+2900352 < MeetspikeHR+1048576 < SwiftUI+5532160"
        )
    }

    func testTheAttributedThreadIsUsedNotTheFirstOne() throws {
        // The first stack in the fixture is another thread (libsystem_pthread); it must not show up.
        let text = try XCTUnwrap(signature(B8Fixtures.crash))
        XCTAssertFalse(text.contains("libsystem_pthread"), text)
    }

    func testHangFollowsTheHeaviestBranchAndHasNoPrefix() {
        // No exceptionType, signal or terminationReason on a hang: frames only.
        XCTAssertEqual(
            signature(B8Fixtures.hang, kind: .hang),
            "Foundation+777 < MeetspikeHR+2097152 < SwiftUI+5532160"
        )
    }

    func testAShortChainUsesWhatItHas() {
        let one = """
        {"callStackTree":{"callStacks":[{"threadAttributed":true,"callStackRootFrames":[
          {"binaryName":"MeetspikeHR","offsetIntoBinaryTextSegment":4096,"sampleCount":9}]}]}}
        """
        XCTAssertEqual(signature(one, kind: .cpu), "MeetspikeHR+4096")
        let two = """
        {"callStackTree":{"callStacks":[{"threadAttributed":true,"callStackRootFrames":[
          {"binaryName":"A","offsetIntoBinaryTextSegment":1,"sampleCount":2,"subFrames":[
            {"binaryName":"B","offsetIntoBinaryTextSegment":2,"sampleCount":2}]}]}]}}
        """
        XCTAssertEqual(signature(two, kind: .disk), "B+2 < A+1")
    }

    func testPrefixAloneWhenThereAreNoFrames() {
        XCTAssertEqual(signature("{\"diagnosticMetaData\":{\"exceptionType\":1,\"signal\":11}}"), "1/11")
        XCTAssertEqual(signature("{\"diagnosticMetaData\":{\"terminationReason\":\"Namespace SIGNAL, Code 11\"}}"),
                       "Namespace SIGNAL, Code 11")
        XCTAssertEqual(signature("{\"diagnosticMetaData\":{\"signal\":6}}"), "6")
    }

    func testAbsentPrefixPartsAreSkippedNotBlank() {
        let json = """
        {"callStackTree":{"callStacks":[{"threadAttributed":true,"callStackRootFrames":[
          {"binaryName":"MeetspikeHR","offsetIntoBinaryTextSegment":4096,"sampleCount":1}]}]},
         "diagnosticMetaData":{"signal":11}}
        """
        XCTAssertEqual(signature(json), "11 | MeetspikeHR+4096")
    }

    func testNothingUsableGivesNil() {
        XCTAssertNil(signature("{}"))
        XCTAssertNil(signature("not json"))
        XCTAssertNil(signature("{\"diagnosticMetaData\":{\"appVersion\":\"1.1\",\"hangDuration\":\"2 sec\"}}"))
        XCTAssertNil(DiagnosticSignature.make(kind: .test, report: .object([:])))
        XCTAssertNil(DiagnosticSignature.make(kind: .exit, report: .object(["exits": .object(["memoryLimit": .number(1)])])))
        XCTAssertNil(DiagnosticSignature.make(kind: .error, report: .object(["message": .string("boom")])))
        XCTAssertNil(DiagnosticSignature.make(kind: .crash, report: .null))
        XCTAssertNil(DiagnosticSignature.make(kind: .crash, report: .array([.number(1)])))
        // Frames with no name or offset are skipped, so nothing is left.
        XCTAssertNil(signature("""
        {"callStackTree":{"callStacks":[{"threadAttributed":true,"callStackRootFrames":[{"sampleCount":1},{"address":5}]}]}}
        """))
    }

    func testWholeNumbersHaveNoDecimalPoint() throws {
        let json = """
        {"callStackTree":{"callStacks":[{"threadAttributed":true,"callStackRootFrames":[
          {"binaryName":"MeetspikeHR","offsetIntoBinaryTextSegment":4294967296,"sampleCount":1}]}]},
         "diagnosticMetaData":{"exceptionType":1,"signal":11.0}}
        """
        XCTAssertEqual(signature(json), "1/11 | MeetspikeHR+4294967296")
    }

    func testIsStableForTheSameCrash() {
        XCTAssertEqual(signature(B8Fixtures.crash), signature(B8Fixtures.crash))
        // A different address (ASLR) with the same offsets is the same crash.
        let moved = B8Fixtures.crash.replacingOccurrences(of: "4300636352", with: "4300999999")
            .replacingOccurrences(of: "6600000000", with: "6611111111")
        XCTAssertEqual(signature(moved), signature(B8Fixtures.crash))
    }

    func testNeverLongerThan200Characters() throws {
        let reason = String(repeating: "r", count: 400)
        let json = """
        {"callStackTree":{"callStacks":[{"threadAttributed":true,"callStackRootFrames":[
          {"binaryName":"MeetspikeHR","offsetIntoBinaryTextSegment":4096,"sampleCount":1}]}]},
         "diagnosticMetaData":{"terminationReason":"\(reason)"}}
        """
        let text = try XCTUnwrap(signature(json))
        XCTAssertLessThanOrEqual(text.count, 200)
        XCTAssertTrue(text.hasPrefix("rrrr"))
    }

    func testWorksForEveryKind() {
        for kind in [DiagnosticReport.Kind.crash, .hang, .cpu, .disk] {
            XCTAssertNotNil(signature(B8Fixtures.crash, kind: kind), "\(kind)")
        }
    }
}
