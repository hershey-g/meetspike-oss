import Foundation
import XCTest
@testable import MeetspikeHRCore

// Shared by the Build9Helpers* files. Fake data only. Uses the clock in Build9Support.swift (`B9.base`).

enum H9 {
    /// A day row the way the Worker sends it, with an override laid on. Times are seconds from `B9.base`.
    static func row(
        _ id: String, title: String = "Standup", start: TimeInterval = 0, end: TimeInterval = 1800,
        override: MeetingOverride? = nil, excluded: Bool? = nil, score: Double? = nil
    ) throws -> Meeting {
        var meeting: Meeting = try MobileJSON.decode(
            Meeting.self, #"{"id":"\#(id)","title":"\#(title)","startUtc":"\#(B9.iso(start))","endUtc":"\#(B9.iso(end))"}"#)
        meeting.override = override
        meeting.excluded = excluded
        meeting.score = score
        return meeting
    }

    static func remote(
        _ id: String = "ev1", title: String = "Standup", start: TimeInterval = 0, end: TimeInterval = 1800,
        override: MeetingOverride? = nil
    ) -> RemoteMeeting {
        RemoteMeeting(id: id, title: title, calendarStart: B9.at(start), calendarEnd: B9.at(end), override: override)
    }

    static func item(_ id: String, _ edit: OverrideEdit, queued: TimeInterval = 0) -> OverrideOutbox.Item {
        OverrideOutbox.Item(eventID: id, edit: edit, queuedAt: B9.at(queued))
    }

    /// The JSON an edit goes over the wire as.
    static func wire(_ edit: OverrideEdit) throws -> [String: Any] {
        let data = try JSONEncoder().encode(edit)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Words shown to a person: no em dash or en dash, not empty.
    static func assertPlainVoice(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), "no dashes in copy: \(text)", file: file, line: line)
        XCTAssertFalse(text.isEmpty, file: file, line: line)
    }
}
