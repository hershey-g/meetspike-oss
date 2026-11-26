import XCTest
@testable import MeetspikeHRCore

final class AppUpdateTests: XCTestCase {
    func testOffersOnlyANewerBuild() {
        XCTAssertEqual(AppUpdate.availableBuild(current: "2", latest: 3), 3)
        XCTAssertNil(AppUpdate.availableBuild(current: "3", latest: 3))
        XCTAssertNil(AppUpdate.availableBuild(current: "4", latest: 3))
    }

    func testUnknownNumbersOfferNothing() {
        XCTAssertNil(AppUpdate.availableBuild(current: nil, latest: 3))
        XCTAssertNil(AppUpdate.availableBuild(current: "1.0", latest: 3))
        XCTAssertNil(AppUpdate.availableBuild(current: "2", latest: nil))
    }

    func testEndpointAndReply() throws {
        let destination = try XCTUnwrap(Destination("https://your-worker.example.com"))
        XCTAssertEqual(destination.latestBuildEndpoint.absoluteString, "https://your-worker.example.com/api/whoop-web/app/ios")
        let reply = try JSONDecoder().decode(LatestBuildReply.self, from: Data(#"{"ok":true,"build":null}"#.utf8))
        XCTAssertNil(reply.build)
    }
}
