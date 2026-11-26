import Foundation

/// A heart icon that beats at the live heart rate: one "lub-dub" per beat,
/// so 60 BPM is one beat a second and 120 BPM is two.
public enum Heartbeat {
    /// Beats outside this range are clamped, so a bad reading can't freeze or blur the icon.
    public static let bpmRange = 30...220

    /// Seconds between beats.
    public static func period(bpm: Int) -> TimeInterval {
        60 / Double(min(max(bpm, bpmRange.lowerBound), bpmRange.upperBound))
    }

    /// How big the heart is right now, from 0 (resting) to 1 (full beat).
    /// A strong first pulse, a softer second one, then rest until the next beat.
    public static func intensity(bpm: Int, at time: TimeInterval) -> Double {
        let period = period(bpm: bpm)
        var elapsed = time.truncatingRemainder(dividingBy: period)
        if elapsed < 0 { elapsed += period }
        // The pulse shape is fixed in seconds (it doesn't stretch at slow rates),
        // but squeezed when beats come faster than it lasts.
        let squeeze = min(1, period / 0.5)
        let t = elapsed / squeeze
        return max(bump(t, peak: 0.05, width: 0.07, height: 1),
                   bump(t, peak: 0.22, width: 0.07, height: 0.55))
    }

    /// The moment the next beat starts, for code that toggles an icon instead of animating it.
    public static func nextBeat(bpm: Int, after time: TimeInterval) -> TimeInterval {
        let period = period(bpm: bpm)
        return (floor(time / period) + 1) * period
    }

    private static func bump(_ t: Double, peak: Double, width: Double, height: Double) -> Double {
        let distance = abs(t - peak)
        guard distance < width else { return 0 }
        // Smooth cosine bump: 1 at the peak, 0 at the edges.
        return height * 0.5 * (1 + cos(.pi * distance / width))
    }
}
