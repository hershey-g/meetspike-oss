import XCTest
@testable import MeetspikeHRCore

final class DatesFixTests: XCTestCase {
    func testCachedAnswerDoesNotMoveToday() {
        XCTAssertFalse(DatesLogic.shouldNoteToday(isFromCache: true))
    }

    func testLiveAnswerMovesToday() {
        XCTAssertTrue(DatesLogic.shouldNoteToday(isFromCache: false))
    }

    func testLogCodeNamesTheCase() {
        XCTAssertEqual(DatesLogic.logCode(APIError.offline), "offline")
        XCTAssertEqual(DatesLogic.logCode(APIError.accessRejected), "accessRejected")
        XCTAssertEqual(DatesLogic.logCode(APIError.notConfigured), "notConfigured")
    }

    func testLogCodeKeepsHTTPStatusButNotMessage() {
        let code = DatesLogic.logCode(APIError.http(status: 502, message: "boom 2026-11-10"))
        XCTAssertEqual(code, "http 502")
        XCTAssertFalse(code.contains("boom"))
    }

    func testLogCodeNeverLeaksDatesOrPaths() {
        let errors: [Error] = [
            APIError.decoding("ViewResponse.2026-11-10 missing"),
            APIError.invalidRequest("/api/view?start=2026-11-10"),
            APIError.http(status: 500, message: "failed for 2026-11-10"),
            NSError(domain: "failed for 2026-11-10 /api/view", code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "failed for 2026-11-10 /api/view"]),
        ]
        for error in errors {
            let code = DatesLogic.logCode(error)
            XCTAssertFalse(code.contains("2026"), "leaked a date: \(code)")
            XCTAssertFalse(code.contains("/api"), "leaked a path: \(code)")
        }
    }

    func testLogCodeForUnknownErrorIsUnknown() {
        XCTAssertEqual(DatesLogic.logCode(NSError(domain: "x", code: 1)), "unknown")
    }
}
