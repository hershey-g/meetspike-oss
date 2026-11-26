import ActivityKit
import MeetspikeHRCore
import SwiftUI
import WidgetKit

@main
struct MeetspikeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MeetspikeGlanceWidget()
        MeetspikeLiveActivity()
    }
}

// MARK: - Next meeting widget

struct GlanceTimelineEntry: TimelineEntry {
    let date: Date
    let glance: GlanceEntry
}

/// Reads what the app wrote to the App Group and lays out entries at every
/// meeting boundary, so countdowns and the ring move without a reload.
struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceTimelineEntry {
        let now = Date.now
        return GlanceTimelineEntry(date: now, glance: GlanceSamples.entry(now: now))
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceTimelineEntry) -> Void) {
        let now = Date.now
        let stored = GlanceStore().load()
        let glance = context.isPreview && stored == nil ? GlanceSamples.entry(now: now) : GlanceEntry(snapshot: stored, at: now)
        completion(GlanceTimelineEntry(date: now, glance: glance))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceTimelineEntry>) -> Void) {
        let now = Date.now
        let entries = GlanceTimeline.entries(for: GlanceStore().load(), from: now)
            .map { GlanceTimelineEntry(date: $0.date, glance: $0) }
        let next = max(entries.last?.date ?? now, now.addingTimeInterval(30 * 60))
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}

struct GlanceWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlanceTimelineEntry

    var body: some View {
        GlanceWidgetView(entry: entry.glance, family: family)
            .containerBackground(for: .widget) {
                if GlanceWidgetView.isSystem(family) { GlanceColor.charcoal } else { Color.clear }
            }
    }
}

struct MeetspikeGlanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MeetspikeGlance", provider: GlanceProvider()) { entry in
            GlanceWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Next meeting")
        .description("Your next meeting, its countdown and your heart rate.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

// MARK: - Live Activity

struct MeetspikeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetspikeActivityAttributes.self) { context in
            GlanceLockScreenView(
                model: GlanceActivityModel(state: context.state, isStale: context.isStale),
                title: context.state.titleLine
            )
                .activityBackgroundTint(GlanceColor.charcoal)
                .activitySystemActionForegroundColor(GlanceColor.text)
        } dynamicIsland: { context in
            let model = GlanceActivityModel(state: context.state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    GlanceIslandExpandedLeading(model: model)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    GlanceIslandExpandedTrailing(model: model)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    GlanceIslandExpandedBottom(model: model, title: context.state.titleLine)
                }
            } compactLeading: {
                GlanceIslandCompactLeading(model: model)
            } compactTrailing: {
                GlanceIslandCompactTrailing(model: model, label: model.state.compactLabel(now: model.now))
            } minimal: {
                GlanceIslandMinimal(model: model)
            }
            .keylineTint(GlanceColor.spike)
        }
    }
}

#if DEBUG
#Preview("Small", as: .systemSmall) {
    MeetspikeGlanceWidget()
} timeline: {
    GlanceTimelineEntry(date: .now, glance: GlanceSamples.entry())
}

#Preview("Lock Screen", as: .content, using: MeetspikeActivityAttributes()) {
    MeetspikeLiveActivity()
} contentStates: {
    GlanceSamples.activity()
    GlanceSamples.activity(status: .reconnecting)
}
#endif
