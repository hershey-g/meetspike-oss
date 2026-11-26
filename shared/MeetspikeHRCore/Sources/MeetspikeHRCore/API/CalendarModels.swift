import Foundation

// Google accounts and the calendars chosen in each (src/routes/calendars.ts).
// GET /api/calendars, PUT /api/calendars/selection and DELETE
// /api/calendars/accounts/:email all answer with this shape.

/// Every connected Google account with its calendars.
public struct GoogleCalendarsResponse: APIModel {
    public var ok: Bool?
    @Items public var accounts: [GoogleAccount]
    /// Where a browser starts Google sign-in for another account ("/auth/google/start").
    public var connectPath: String?
    /// The setup page section with the same controls ("/setup#calendars").
    public var setupPath: String?
    /// The old single-account sign-in could not be moved yet (Google unreachable or expired).
    public var legacyError: String?
    // PUT /selection extras
    public var changed: Int?
    public var hidden: Int?
    public var shown: Int?
    /// Saved, but the sync that fills a newly chosen calendar failed.
    public var syncError: String?
    // DELETE extra
    public var removed: Bool?

    public init(accounts: [GoogleAccount] = []) {
        self.accounts = accounts
    }
}

public struct GoogleAccount: APIModel, Identifiable {
    public var email: String
    public var connectedAt: String?
    public var lastSyncAt: String?
    public var error: String?
    @Items public var calendars: [GoogleCalendar]

    public var id: String { email }

    public init(email: String, connectedAt: String? = nil, lastSyncAt: String? = nil, error: String? = nil,
                calendars: [GoogleCalendar] = []) {
        self.email = email
        self.connectedAt = connectedAt
        self.lastSyncAt = lastSyncAt
        self.error = error
        self.calendars = calendars
    }
}

public struct GoogleCalendar: APIModel, Identifiable {
    public var id: String
    public var name: String?
    public var primary: Bool?
    public var selected: Bool?
    /// "#rrggbb" from Google, or nil.
    public var color: String?
    public var accessRole: String?
    public var lastSyncAt: String?
    public var error: String?

    public init(id: String, name: String? = nil, primary: Bool? = nil, selected: Bool? = nil, color: String? = nil,
                accessRole: String? = nil, lastSyncAt: String? = nil, error: String? = nil) {
        self.id = id
        self.name = name
        self.primary = primary
        self.selected = selected
        self.color = color
        self.accessRole = accessRole
        self.lastSyncAt = lastSyncAt
        self.error = error
    }

    public var isPrimary: Bool { primary == true }
    public var isSelected: Bool { selected == true }
}

/// One change for PUT /api/calendars/selection.
public struct CalendarSelection: Encodable, Equatable, Sendable {
    public var account: String
    public var calendarId: String
    public var selected: Bool

    public init(account: String, calendarId: String, selected: Bool) {
        self.account = account
        self.calendarId = calendarId
        self.selected = selected
    }
}

extension APIRequest {
    /// GET /api/calendars. `refresh: false` sends `refresh=0`: stored state only, no Google call.
    /// Never cached: a stale switch would be worse than an error.
    public static func calendars(refresh: Bool = true) -> APIRequest {
        APIRequest(path: "/api/calendars", query: refresh ? [] : [.init(name: "refresh", value: "0")],
                   timeout: 30, cacheable: false)
    }

    /// PUT /api/calendars/selection `{"selections":[{"account","calendarId","selected"}]}`.
    /// Choosing a calendar syncs it before answering, so it waits longer.
    public static func setCalendarSelection(_ selections: [CalendarSelection]) throws -> APIRequest {
        struct Body: Encodable { var selections: [CalendarSelection] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return APIRequest(method: .put, path: "/api/calendars/selection",
                          body: try encoder.encode(Body(selections: selections)), timeout: 60, cacheable: false)
    }

    /// DELETE /api/calendars/accounts/:email
    public static func disconnectGoogleAccount(email: String) -> APIRequest {
        APIRequest(method: .delete, path: "/api/calendars/accounts/\(encode(email))", timeout: 30, cacheable: false)
    }
}
