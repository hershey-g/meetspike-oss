#if DEBUG
import MeetspikeHRCore
import SwiftUI
import WidgetKit

/// Debug-only ways to see the Live Activity and widgets in the simulator.
/// Launch with `-demo live -demoActivity YES` to start the real Live Activity
/// from fixture data, and `-demoGlanceGallery YES` to render every glance view
/// to PNGs in the app's Documents/GlanceGallery folder.
extension PhoneModel {
    func showDemoGlance() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "demoActivity") { glance.refresh(glanceInput) }
        if defaults.bool(forKey: "demoGlanceGallery") { GlanceGallery.renderAll() }
    }
}

@MainActor
enum GlanceGallery {
    static func renderAll() {
        let folder = URL.documentsDirectory.appendingPathComponent("GlanceGallery", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date.now
        for (name, size) in [("glance-gallery", DynamicTypeSize.large), ("glance-gallery-large-type", .accessibility2)] {
            let renderer = ImageRenderer(content: GlanceGallerySheet(now: now).environment(\.dynamicTypeSize, size))
            renderer.scale = 3
            if let data = renderer.uiImage?.pngData() {
                try? data.write(to: folder.appendingPathComponent("\(name).png"))
            }
        }
    }
}

/// Every glance view on one sheet, at its real point size.
private struct GlanceGallerySheet: View {
    let now: Date

    private var live: GlanceActivityModel { GlanceActivityModel(state: GlanceSamples.activity(now: now), now: now) }

    private var reconnecting: GlanceActivityModel {
        GlanceActivityModel(state: GlanceSamples.activity(now: now, status: .reconnecting), now: now)
    }

    private var waiting: GlanceActivityModel {
        var state = GlanceSamples.activity(now: now, status: .waiting)
        state.phase = .startsIn
        state.timerFrom = now.addingTimeInterval(-20)
        state.timerTo = now.addingTimeInterval(100)
        return GlanceActivityModel(state: state, now: now)
    }

    private var goLive: GlanceActivityModel {
        let state = LiveGlanceContent(bpm: 71, status: .live, title: LiveGlancePlan.goLiveTitle, phase: .open,
                                      timerFrom: now.addingTimeInterval(-262), timerTo: nil, meetingStart: nil, meetingEnd: nil)
        return GlanceActivityModel(state: state, now: now)
    }

    private var peakEntry: GlanceEntry {
        var snapshot = GlanceSamples.snapshot(now: now)
        snapshot.meetings.removeFirst()
        snapshot.latestAt = now.addingTimeInterval(-3_600)
        return GlanceEntry(snapshot: snapshot, at: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            label("Lock Screen: live, reconnecting, waiting, Go live")
            ForEach(Array([live, reconnecting, waiting, goLive].enumerated()), id: \.offset) { _, model in
                GlanceLockScreenView(model: model)
                    .frame(width: 370)
                    .background(GlanceColor.charcoal, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }

            label("Dynamic Island: compact, minimal, expanded")
            HStack(spacing: 14) {
                HStack {
                    GlanceIslandCompactLeading(model: live)
                    Spacer(minLength: 110)
                    GlanceIslandCompactTrailing(model: live)
                }
                .padding(.horizontal, 14)
                .frame(height: 37)
                .background(.black, in: Capsule())
                GlanceIslandMinimal(model: live)
                    .frame(width: 37, height: 37)
                    .background(.black, in: Circle())
            }
            VStack(spacing: 8) {
                HStack(alignment: .top) {
                    GlanceIslandExpandedLeading(model: live)
                    Spacer()
                    GlanceIslandExpandedTrailing(model: live)
                }
                GlanceIslandExpandedBottom(model: live)
            }
            .padding(16)
            .frame(width: 370)
            .background(.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))

            label("Home Screen: small and medium, live and last peak")
            HStack(spacing: 18) {
                widget(GlanceSamples.entry(now: now), .systemSmall, 170, 170)
                widget(peakEntry, .systemSmall, 170, 170)
            }
            widget(GlanceSamples.entry(now: now), .systemMedium, 364, 170)
            widget(peakEntry, .systemMedium, 364, 170)

            label("Lock Screen widgets")
            HStack(spacing: 14) {
                GlanceWidgetView(entry: GlanceSamples.entry(now: now), family: .accessoryRectangular)
                    .frame(width: 172, height: 76)
                GlanceWidgetView(entry: GlanceSamples.entry(now: now), family: .accessoryCircular)
                    .frame(width: 76, height: 76)
                GlanceWidgetView(entry: peakEntry, family: .accessoryCircular)
                    .frame(width: 76, height: 76)
            }
            .foregroundStyle(.white)
            .padding(12)
            .background(Color(white: 0.28), in: RoundedRectangle(cornerRadius: 18))
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
        .background(Color(white: 0.42))
        .environment(\.colorScheme, .dark)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(.white)
    }

    private func widget(_ entry: GlanceEntry, _ family: WidgetFamily, _ width: CGFloat, _ height: CGFloat) -> some View {
        GlanceWidgetView(entry: entry, family: family)
            .padding(16)
            .frame(width: width, height: height)
            .background(GlanceColor.charcoal, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
#endif
