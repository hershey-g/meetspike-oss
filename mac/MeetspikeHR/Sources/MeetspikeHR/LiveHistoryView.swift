import Charts
import Foundation
import MeetspikeHRCore
import SwiftUI

@MainActor
struct LiveHistoryView: View {
    let logger: Logger
    let meeting: LiveMeeting?
    @State private var showMeeting = false
    @State private var history: HeartRateHistory?
    @State private var unavailable = false

    private var selectedMeeting: LiveMeeting? { showMeeting ? meeting : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let meeting {
                Picker("Heart-rate history", selection: $showMeeting) {
                    Text("Last 15 min").tag(false)
                    Text("Meeting").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                if showMeeting {
                    Text(meeting.title ?? "Current meeting").font(.subheadline.weight(.medium)).lineLimit(2)
                }
            } else {
                Text("Last 15 minutes").font(.subheadline.weight(.medium))
            }

            if let history, !history.points.isEmpty {
                chart(history)
                    .frame(height: 123)
                    .accessibilityLabel("Heart-rate history in beats per minute")
                HStack(spacing: 15) {
                    if let stats = history.stats {
                        metric("Min", stats.min)
                        metric("Avg", stats.avg)
                        metric("Max", stats.max)
                    }
                    Spacer(minLength: 0)
                    if selectedMeeting != nil {
                        Text("10-min pads shaded").foregroundStyle(.secondary)
                    }
                }.font(.caption)
            } else {
                Text(unavailable ? "History is temporarily unavailable." : "Waiting for readings in this window.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .center)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .task(id: selectedMeeting) {
            let meeting = selectedMeeting
            history = nil
            repeat {
                let now = Date.now
                let range = meeting.map { $0.paddedStart...$0.paddedEnd } ?? (now.addingTimeInterval(-900)...now)
                do {
                    let readings = try await logger.readings(in: range)
                    guard !Task.isCancelled else { return }
                    history = HeartRateHistory(readings: readings, range: range, meeting: meeting)
                    unavailable = false
                } catch {
                    guard !Task.isCancelled else { return }
                    unavailable = true
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            } while !Task.isCancelled
        }
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value, format: .number).fontWeight(.semibold).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func chart(_ history: HeartRateHistory) -> some View {
        Chart {
            if let meeting = history.meeting {
                RectangleMark(xStart: .value("Pad starts", meeting.paddedStart), xEnd: .value("Meeting starts", meeting.startUtc))
                    .foregroundStyle(Color.accentColor.opacity(0.12))
                    .accessibilityHidden(true)
                RectangleMark(xStart: .value("Meeting ends", meeting.endUtc), xEnd: .value("Pad ends", meeting.paddedEnd))
                    .foregroundStyle(Color.accentColor.opacity(0.12))
                    .accessibilityHidden(true)
                RuleMark(x: .value("Meeting starts", meeting.startUtc))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            ForEach(history.points) { point in
                if point.isolated {
                    PointMark(x: .value("Time", point.reading.time), y: .value("BPM", point.reading.bpm))
                        .foregroundStyle(Color.accentColor).symbolSize(12)
                } else {
                    LineMark(x: .value("Time", point.reading.time), y: .value("BPM", point.reading.bpm),
                             series: .value("Segment", point.segment))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.accentColor)
                }
            }
            if let last = history.points.last?.reading {
                PointMark(x: .value("Latest reading", last.time), y: .value("BPM", last.bpm))
                    .foregroundStyle(Color.accentColor).symbolSize(24)
            }
        }
        .chartXScale(domain: history.range)
        .chartYScale(domain: history.bpmRange)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
        }
        .chartLegend(.hidden)
    }
}
