import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 8, track `app`, D1: the report the phone sends to its own Worker (POST /api/whoop-web/app/diagnostics).
//
// A missing type stops this whole test target compiling, so the names below are fixed here. They stay inside the
// spec's names (spec8.md, "App track"); where the spec leaves a shape open, this header chooses and the tests pin it.
// All of it lives in shared/MeetspikeHRCore/Sources/MeetspikeHRCore/Mobile/Diagnostics/ and is public (the iOS
// target uses it); the tests use @testable.
//
//   public indirect enum DiagnosticValue: Codable, Equatable, Sendable
//       case object([String: DiagnosticValue]), array([DiagnosticValue]), string(String), number(Double),
//            bool(Bool), null
//       Plain JSONEncoder/JSONDecoder round trip (no custom strategies needed by callers).
//
//   public struct DiagnosticReport: Codable, Equatable, Sendable
//       public enum Kind: String, Codable, Sendable { crash, hang, cpu, disk, exit, error, test }
//       public init(id: UUID, kind: Kind, at: Date, build: Int, version: String, os: String, device: String,
//                   signature: String? = nil, report: DiagnosticValue, crumbs: [String] = [])
//       public var id, kind, at, build, version, os, device, signature, report, crumbs   (all `var`)
//       `JSONEncoder().encode(report)` with NO strategies set (the caller may add .sortedKeys) is the server body:
//           { id: lowercase uuid, kind, at: "2026-11-25T05:00:00.125Z" (ISO, always 3 ms digits, Z), app: "ios",
//             build: 8 (an integer), version, os, device, signature (left out when nil), report,
//             crumbs (left out when empty) }
//       `JSONDecoder().decode(DiagnosticReport.self, ...)` reads that back (ignores `app`) and round trips equal.
//
// Shared helpers for every Build8 test file live at the bottom of this file (enum B8).

final class Build8DiagnosticReportTests: XCTestCase {
    private let id = UUID(uuidString: "A1B2C3D4-0000-4000-8000-0000000000AB")!
    private let at = Date(timeIntervalSince1970: B8.t0 + 0.125)

    private func make(
        kind: DiagnosticReport.Kind = .crash, signature: String? = nil, report: DiagnosticValue = .object([:]),
        crumbs: [String] = []
    ) -> DiagnosticReport {
        DiagnosticReport(
            id: id, kind: kind, at: at, build: 8, version: "1.1", os: "iPhone OS 26.1 (23B85)", device: "iPhone16,2",
            signature: signature, report: report, crumbs: crumbs
        )
    }

    private func wire(_ report: DiagnosticReport, sorted: Bool = false) throws -> (text: String, object: [String: Any]) {
        let encoder = JSONEncoder()
        if sorted { encoder.outputFormatting = [.sortedKeys] }
        let data = try encoder.encode(report)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (String(decoding: data, as: UTF8.self), try XCTUnwrap(object))
    }

    func testExactWireBodyWithEveryField() throws {
        let report = make(
            signature: "6/5/Namespace SIGNAL, Code 5 | MeetspikeHR+1048576 < SwiftUI+5532160",
            report: .object(["diagnosticMetaData": .object(["appBuildVersion": .string("8"), "signal": .number(5)])]),
            crumbs: ["2026-11-25T04:59:58.000Z tab today", "2026-11-25T04:59:59.500Z dayLoad 812ms ok"]
        )
        let (_, object) = try wire(report)
        let expected: [String: Any] = [
            "id": "a1b2c3d4-0000-4000-8000-0000000000ab",
            "kind": "crash",
            "at": "2026-11-25T05:00:00.125Z",
            "app": "ios",
            "build": 8,
            "version": "1.1",
            "os": "iPhone OS 26.1 (23B85)",
            "device": "iPhone16,2",
            "signature": "6/5/Namespace SIGNAL, Code 5 | MeetspikeHR+1048576 < SwiftUI+5532160",
            "report": ["diagnosticMetaData": ["appBuildVersion": "8", "signal": 5]],
            "crumbs": ["2026-11-25T04:59:58.000Z tab today", "2026-11-25T04:59:59.500Z dayLoad 812ms ok"],
        ]
        XCTAssertEqual(NSDictionary(dictionary: object), NSDictionary(dictionary: expected))
    }

    func testBodyHasExactlyTheServerFieldsAndNothingElse() throws {
        let (_, object) = try wire(make(signature: "x", crumbs: ["a"]))
        XCTAssertEqual(
            Set(object.keys),
            ["id", "kind", "at", "app", "build", "version", "os", "device", "signature", "report", "crumbs"]
        )
    }

    func testUUIDIsLowercaseOnTheWire() throws {
        let (text, object) = try wire(make())
        XCTAssertEqual(object["id"] as? String, "a1b2c3d4-0000-4000-8000-0000000000ab")
        XCTAssertFalse(text.contains("A1B2C3D4"), text)
    }

    func testDateIsISOWithThreeMillisecondDigitsAndZ() throws {
        let cases: [(TimeInterval, String)] = [
            (B8.t0, "2026-11-25T05:00:00.000Z"),
            (B8.t0 + 0.5, "2026-11-25T05:00:00.500Z"),
            (B8.t0 + 0.125, "2026-11-25T05:00:00.125Z"),
            (B8.t0 + 86_399, "2026-11-26T04:59:59.000Z"),
            (0, "1970-01-01T00:00:00.000Z"),
        ]
        for (seconds, expected) in cases {
            var report = make()
            report.at = Date(timeIntervalSince1970: seconds)
            XCTAssertEqual(try wire(report).object["at"] as? String, expected)
        }
    }

    func testAppIsAlwaysIOSAndBuildIsAnInteger() throws {
        let (text, object) = try wire(make(), sorted: true)
        XCTAssertEqual(object["app"] as? String, "ios")
        XCTAssertTrue(text.contains("\"build\":8,") || text.contains("\"build\":8}"), "build must be 8, not 8.0: \(text)")
    }

    func testEmptyCrumbsAndNilSignatureAreLeftOut() throws {
        let (_, object) = try wire(make(signature: nil, crumbs: []))
        XCTAssertNil(object["crumbs"])
        XCTAssertNil(object["signature"])
        // An empty-string signature is still a value the caller chose to send, so it stays.
        XCTAssertEqual(try wire(make(signature: "")).object["signature"] as? String, "")
    }

    func testEveryKindEncodesItsServerName() throws {
        let names = ["crash", "hang", "cpu", "disk", "exit", "error", "test"]
        for name in names {
            let kind = try XCTUnwrap(DiagnosticReport.Kind(rawValue: name), name)
            XCTAssertEqual(try wire(make(kind: kind)).object["kind"] as? String, name)
        }
        XCTAssertNil(DiagnosticReport.Kind(rawValue: "bogus"))
        XCTAssertNil(DiagnosticReport.Kind(rawValue: "Crash"))
    }

    func testReportValueKeepsEveryJSONType() throws {
        let value: DiagnosticValue = .object([
            "s": .string("hi"), "n": .number(3), "f": .number(0.5), "b": .bool(true), "z": .null,
            "a": .array([.number(1), .string("two"), .object(["k": .bool(false)])]),
        ])
        let (_, object) = try wire(make(report: value))
        let expected: [String: Any] = [
            "s": "hi", "n": 3, "f": 0.5, "b": true, "z": NSNull(), "a": [1, "two", ["k": false]],
        ]
        XCTAssertEqual(NSDictionary(dictionary: try XCTUnwrap(object["report"] as? [String: Any])), NSDictionary(dictionary: expected))
    }

    func testBooleansAndNumbersStayDistinct() throws {
        // A Bool must not turn into 1 and a 1 must not turn into true.
        let data = try JSONEncoder().encode(DiagnosticValue.array([.bool(true), .number(1), .bool(false), .number(0)]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self).replacingOccurrences(of: " ", with: ""), "[true,1,false,0]")
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticValue.self, from: data),
                       .array([.bool(true), .number(1), .bool(false), .number(0)]))
    }

    func testRoundTripThroughWireJSON() throws {
        let report = make(
            kind: .hang, signature: "sig", report: .object(["hangDuration": .string("2.5 sec"), "list": .array([.null])]),
            crumbs: ["a", "b"]
        )
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticReport.self, from: data), report)
        // Without the optional parts.
        let bare = make()
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticReport.self, from: JSONEncoder().encode(bare)), bare)
    }

    func testDecodingReadsAServerShapedBodyWithoutSignatureOrCrumbs() throws {
        let body = """
        {"id":"a1b2c3d4-0000-4000-8000-0000000000ab","kind":"test","at":"2026-11-25T05:00:00.000Z","app":"ios",
         "build":8,"version":"1.1","os":"iPhone OS 26.1","device":"iPhone16,2","report":{"message":"hi"}}
        """
        let report = try JSONDecoder().decode(DiagnosticReport.self, from: Data(body.utf8))
        XCTAssertEqual(report.id, id)
        XCTAssertEqual(report.kind, .test)
        XCTAssertEqual(report.at, Date(timeIntervalSince1970: B8.t0))
        XCTAssertNil(report.signature)
        XCTAssertEqual(report.crumbs, [])
        XCTAssertEqual(report.report, .object(["message": .string("hi")]))
    }

    func testDecodingRejectsAnUnknownKindAndABadDate() {
        let good = """
        {"id":"a1b2c3d4-0000-4000-8000-0000000000ab","kind":"%KIND%","at":"%AT%","app":"ios",
         "build":8,"version":"1.1","os":"x","device":"y","report":{}}
        """
        for (kind, at) in [("bogus", "2026-11-25T05:00:00.000Z"), ("crash", "yesterday"), ("crash", "")] {
            let body = good.replacingOccurrences(of: "%KIND%", with: kind).replacingOccurrences(of: "%AT%", with: at)
            XCTAssertThrowsError(try JSONDecoder().decode(DiagnosticReport.self, from: Data(body.utf8)), "\(kind) \(at)")
        }
    }

    func testReportIsSendableAndEquatable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }
        let a = requireSendable(make())
        var b = a
        XCTAssertEqual(a, b)
        b.build = 9
        XCTAssertNotEqual(a, b)
    }
}

// MARK: Shared helpers

enum B8 {
    /// 2026-11-25T05:00:00Z
    static let t0: TimeInterval = 1_795_582_800

    static func date(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: t0 + offset) }

    /// A parsed Foundation tree (NSDictionary, NSArray, NSString, NSNumber) from an encoded DiagnosticValue.
    static func tree(_ value: DiagnosticValue) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Sorted-key JSON text of a value, for "does this text appear anywhere" leak checks.
    static func text(_ value: DiagnosticValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func parse(_ json: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    }

    /// Asserts that a DiagnosticValue is JSON-equal to the literal JSON text.
    static func assertEqual(
        _ value: DiagnosticValue, _ json: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            let actual = try tree(value) as AnyObject
            let expected = try parse(json) as AnyObject
            let shown = try text(value)
            XCTAssertTrue(actual.isEqual(expected), "\nactual:   \(shown)\nexpected: \(json)", file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    /// Container nesting depth of a value (a leaf is 0, an empty object is 1).
    static func depth(_ value: DiagnosticValue) -> Int {
        switch value {
        case .object(let map): return 1 + (map.values.map(depth).max() ?? 0)
        case .array(let items): return 1 + (items.map(depth).max() ?? 0)
        default: return 0
        }
    }

    /// Every value in the tree, containers included.
    static func nodeCount(_ value: DiagnosticValue) -> Int {
        switch value {
        case .object(let map): return 1 + map.values.map(nodeCount).reduce(0, +)
        case .array(let items): return 1 + items.map(nodeCount).reduce(0, +)
        default: return 1
        }
    }

    /// Every string in the tree.
    static func strings(_ value: DiagnosticValue) -> [String] {
        switch value {
        case .object(let map): return map.values.flatMap(strings)
        case .array(let items): return items.flatMap(strings)
        case .string(let text): return [text]
        default: return []
        }
    }

    static func tempDirectory(_ name: String = "b8") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetspike-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    static func files(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    static func report(
        _ n: Int, at offset: TimeInterval? = nil, kind: DiagnosticReport.Kind = .crash, signature: String? = nil
    ) -> DiagnosticReport {
        DiagnosticReport(
            id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!, kind: kind,
            at: date(offset ?? TimeInterval(n)), build: 8, version: "1.1", os: "iPhone OS 26.1 (23B85)",
            device: "iPhone16,2", signature: signature, report: .object(["signal": .number(Double(n))]), crumbs: ["c\(n)"]
        )
    }
}
