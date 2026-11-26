import Foundation

public struct HeartRateHistory {
    public struct Point: Identifiable {
        public let reading: HeartRatePoint
        public let segment: Int
        public let isolated: Bool
        public var id: HeartRatePoint.ID { reading.id }
    }

    public let range: ClosedRange<Date>
    /// Set by the Mac, which gets the meeting from the Worker. The iPhone passes a window instead.
    public let meeting: LiveMeeting?
    /// The meeting's start and end. With one, `stats` covers only readings inside it.
    public let meetingWindow: ClosedRange<Date>?
    public let points: [Point]
    public let bpmRange: ClosedRange<Int>
    public let stats: (min: Int, avg: Int, max: Int)?

    public init(readings: [HeartRatePoint], range: ClosedRange<Date>, meeting: LiveMeeting?) {
        self.init(readings: readings, range: range, meeting: meeting,
                  meetingWindow: meeting.flatMap { $0.startUtc <= $0.endUtc ? $0.startUtc...$0.endUtc : nil })
    }

    /// For a meeting from the phone's calendar (`CalendarMeeting.start...end`).
    public init(readings: [HeartRatePoint], range: ClosedRange<Date>, meetingWindow: ClosedRange<Date>?) {
        self.init(readings: readings, range: range, meeting: nil, meetingWindow: meetingWindow)
    }

    private init(readings: [HeartRatePoint], range: ClosedRange<Date>, meeting: LiveMeeting?,
                 meetingWindow: ClosedRange<Date>?) {
        self.range = range
        self.meeting = meeting
        self.meetingWindow = meetingWindow
        let values = readings.map(\.bpm)
        bpmRange = ((values.min() ?? 60) - 5)...((values.max() ?? 80) + 5)
        // A Worker meeting that ends before it starts has no window and, as before, no readings inside it.
        let inside = meetingWindow.map { window in readings.filter { window.contains($0.time) }.map(\.bpm) }
            ?? (meeting == nil ? values : [])
        if let minimum = inside.min(), let maximum = inside.max() {
            stats = (minimum, Int((Double(inside.reduce(0, +)) / Double(inside.count)).rounded()), maximum)
        } else {
            stats = nil
        }

        var plotted: [Point] = []
        var start = 0
        var segment = 0
        let stride = max(1, readings.count / 420)
        for index in readings.indices {
            let end = index + 1
            if end < readings.count, readings[end].timeMs - readings[index].timeMs <= 15_000 { continue }
            for offset in Swift.stride(from: start, to: end, by: stride) {
                plotted.append(Point(reading: readings[offset], segment: segment, isolated: end - start == 1))
            }
            if plotted.last?.id != readings[index].id {
                plotted.append(Point(reading: readings[index], segment: segment, isolated: false))
            }
            start = end
            segment += 1
        }
        points = plotted
    }
}
