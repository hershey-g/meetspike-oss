import Foundation
import XCTest
@testable import MeetspikeHRCore

/// Helpers shared by the Today, Dates, People, Ask and More acceptance tests. Fake data only.
enum MobileJSON {
    /// Builds an API model the way the app does: by decoding Worker-shaped JSON. The API models have no public
    /// memberwise initialisers on purpose, so tests describe them as JSON.
    static func decode<T: Decodable>(_ type: T.Type = T.self, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// Epoch milliseconds for an ISO-8601 timestamp.
    static func ms(_ iso: String, file: StaticString = #filePath, line: UInt = #line) -> Double {
        guard let date = APITime.parse(iso) else {
            XCTFail("bad timestamp \(iso)", file: file, line: line)
            return 0
        }
        return date.timeIntervalSince1970 * 1000
    }
}

extension Array {
    /// Out of range gives nil, so a placeholder implementation fails assertions instead of crashing the run.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
