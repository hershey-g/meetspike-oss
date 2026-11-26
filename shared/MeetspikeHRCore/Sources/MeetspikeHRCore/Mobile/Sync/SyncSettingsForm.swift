import Foundation

/// The "Meetspike sync" fields in Settings: whether Save can run, and why not.
/// Secret fields left blank keep the saved values, but only for the same
/// address: saved keys are never sent to a server they did not come from.
public struct SyncSettingsForm: Equatable, Sendable {
    public var origin: String
    public var ingest: String
    public var accessID: String
    public var accessSecret: String
    public var savedOrigin: String
    public var hasSavedIngest: Bool

    public init(origin: String = "", ingest: String = "", accessID: String = "", accessSecret: String = "",
                savedOrigin: String = "", hasSavedIngest: Bool = false) {
        self.origin = origin
        self.ingest = ingest
        self.accessID = accessID
        self.accessSecret = accessSecret
        self.savedOrigin = savedOrigin
        self.hasSavedIngest = hasSavedIngest
    }

    public enum Problem: Equatable, Sendable {
        case origin, ingestMissing, ingestNewServer, ingestInvalid, accessIncomplete, accessInvalid

        public var message: String {
            switch self {
            case .origin: "Enter an https:// address, like https://meetspike.example.com."
            case .ingestMissing: "Enter the ingest secret."
            case .ingestNewServer: "New address: enter its ingest secret. Saved keys stay with the old one."
            case .ingestInvalid: "The ingest secret can't contain spaces."
            case .accessIncomplete: "Fill in both Access fields, or leave both blank."
            case .accessInvalid: "Access fields can't contain spaces."
            }
        }
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ origin: String) -> String {
        Destination(origin)?.origin.absoluteString ?? trimmed(origin)
    }

    public var hasChanges: Bool {
        Self.normalized(origin) != Self.normalized(savedOrigin)
            || [ingest, accessID, accessSecret].contains { !Self.trimmed($0).isEmpty }
    }

    /// True when the address differs from the saved one. Saved secrets belong to the saved address.
    public var originChanged: Bool {
        !Self.trimmed(savedOrigin).isEmpty && Self.normalized(origin) != Self.normalized(savedOrigin)
    }

    public var problem: Problem? {
        if Destination(origin) == nil { return .origin }
        let secret = Self.trimmed(ingest)
        if secret.isEmpty, !hasSavedIngest { return .ingestMissing }
        if secret.isEmpty, originChanged { return .ingestNewServer }
        if !secret.isEmpty, !Credentials.isHeaderValue(secret) { return .ingestInvalid }
        let id = Self.trimmed(accessID)
        let key = Self.trimmed(accessSecret)
        if id.isEmpty != key.isEmpty { return .accessIncomplete }
        if !id.isEmpty, !(Credentials.isHeaderValue(id) && Credentials.isHeaderValue(key)) { return .accessInvalid }
        return nil
    }

    public var canSave: Bool { hasChanges && problem == nil }

    /// Shown under a disabled Save button. Nil when nothing changed: there is nothing to explain.
    public var hint: String? { hasChanges ? problem?.message : nil }
}
