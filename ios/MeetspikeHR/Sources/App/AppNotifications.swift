import Foundation
import MeetspikeHRCore

/// Cross-tab signals. Tabs never call each other; they post and observe these on `NotificationCenter.default`.
/// Documented in shared/MeetspikeHRCore/Sources/MeetspikeHRCore/API/CONTRACT.md ("Cross-tab notifications").
extension Notification.Name {
    /// More posted this after a Show Oura / Show WHOOP toggle. `userInfo["source"]` is "oura" or "whoop"
    /// (use `Notification.displaySource`). Today, Dates and People refetch; Ask clears its chat.
    static let meetspikeDisplaySourcesChanged = Notification.Name("com.meetspike.displaySourcesChanged")

    /// Posted after a calendar or wearable sync finished. Today, Dates and People refetch.
    static let meetspikeDataRefreshed = Notification.Name("com.meetspike.dataRefreshed")

    /// A company page saved or cleared a company name. Pages that show company names refetch; nothing is
    /// treated as synced (unlike `.meetspikeDataRefreshed`, which Today counts as a sync).
    static let meetspikeCompanyRenamed = Notification.Name("com.meetspike.companyRenamed")

    /// More's AI key row posts this after switching to the Ask tab. Ask shows its key form.
    static let meetspikeOpenAskKeyForm = Notification.Name("com.meetspike.openAskKeyForm")

    /// Menu removed the AI key (and the saved chat file). A live Ask tab clears its in-memory chat.
    static let meetspikeAskKeyRemoved = Notification.Name("com.meetspike.askKeyRemoved")
}

extension Notification {
    /// userInfo key for `.meetspikeDisplaySourcesChanged`.
    static let displaySourceKey = "source"

    /// Which source the toggle was for, or nil when the userInfo is missing or unknown.
    var displaySource: SourceDisplay.Source? {
        (userInfo?[Notification.displaySourceKey] as? String).flatMap(SourceDisplay.Source.init(rawValue:))
    }
}

extension NotificationCenter {
    /// Post `.meetspikeDisplaySourcesChanged` for a toggled source.
    func postDisplaySourcesChanged(source: SourceDisplay.Source) {
        post(name: .meetspikeDisplaySourcesChanged, object: nil, userInfo: [Notification.displaySourceKey: source.rawValue])
    }

    func postDataRefreshed() { post(name: .meetspikeDataRefreshed, object: nil) }
    func postCompanyRenamed() { post(name: .meetspikeCompanyRenamed, object: nil) }
    func postOpenAskKeyForm() { post(name: .meetspikeOpenAskKeyForm, object: nil) }
    func postAskKeyRemoved() { post(name: .meetspikeAskKeyRemoved, object: nil) }
}
