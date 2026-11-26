import Charts
import MeetspikeHRCore
import SwiftUI

/// Next-morning recovery for each day: a line that breaks at days without a score, hollow markers, a dashed
/// "usual" line and the three lowest days labelled (`recoveryChart` in public/app.js).
struct DatesRecoveryChart: View {
    let series: [SeriesDay]
    let usual: Double?
    let scoreLabel: String
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 150

    var body: some View {
        let runs = DatesChartMath.segments(series)
        let lows = DatesLogic.lowestRecoveryDays(series)
        let lowIndexes = Set(lows.map(\.index))
        let marker = CGFloat(DatesChartMath.markerSize(count: series.count))
        Chart {
            if let usual {
                RuleMark(y: .value("Usual", usual))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
            }
            ForEach(runs.indices, id: \.self) { run in
                ForEach(runs[run]) { point in
                    LineMark(x: .value("Day", point.day), y: .value("Score", point.value), series: .value("Run", "run\(run)"))
                        .foregroundStyle(Theme.good)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                }
            }
            ForEach(runs.flatMap { $0 }) { point in
                PointMark(x: .value("Day", point.day), y: .value("Score", point.value))
                    .symbol {
                        Circle()
                            .fill(Theme.card)
                            .overlay(Circle().strokeBorder(Theme.good, lineWidth: 2))
                            .frame(width: marker, height: marker)
                    }
                    .annotation(position: .bottom, spacing: 3) {
                        if lowIndexes.contains(point.index) {
                            Text("\(DatesFormat.percent(point.value))%")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: series.map(\.day))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary(lows))
    }

    private func summary(_ lows: [DatesLowDay]) -> String {
        var text = "Next-morning \(scoreLabel) for each day"
        if let lowest = lows.first { text += ", lowest \(DatesFormat.percent(lowest.value)) percent" }
        return text
    }
}

/// Hours of meetings each day as bars (`hoursChart` in public/app.js).
struct DatesHoursChart: View {
    let series: [SeriesDay]
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 130

    var body: some View {
        let top = DatesChartMath.hoursMax(series)
        let width = CGFloat(DatesChartMath.barWidth(count: series.count))
        Chart(series) { day in
            BarMark(x: .value("Day", day.day), y: .value("Hours", day.meetingHours ?? 0), width: .fixed(width))
                .cornerRadius(2)
                .foregroundStyle(Color.indigo)
        }
        .chartYScale(domain: 0...top)
        .chartXScale(domain: series.map(\.day))
        .chartYAxis {
            AxisMarks(values: [0, top.rounded()]) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: DatesChartMath.labelledDays(series)) { value in
                AxisValueLabel {
                    if let day = value.as(String.self) {
                        VStack(spacing: 0) {
                            Text(DatesFormat.narrowWeekday(day))
                            Text(DatesFormat.dayNumber(day))
                        }
                        .font(.caption2)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hours of meetings each day")
        .accessibilityValue(spoken)
    }

    private var spoken: String {
        guard let busiest = series.max(by: { ($0.meetingHours ?? 0) < ($1.meetingHours ?? 0) }),
              (busiest.meetingHours ?? 0) > 0 else { return "No meetings" }
        return "Busiest day \(DatesFormat.longDay(busiest.day)), \(DatesFormat.number(busiest.meetingHours ?? 0)) hours"
    }
}
