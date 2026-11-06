import Foundation

/// Percentile `p` (0...1) of `xs` (nearest rank), 0 for none.
public func percentile(_ xs: [Double], _ p: Double) -> Double {
    if xs.isEmpty { return 0 }
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}

public func f3(_ x: Double) -> String { unsafe String(format: "%.3f", x) }
public func f2(_ x: Double) -> String { unsafe String(format: "%.2f", x) }
public func f1(_ x: Double) -> String { unsafe String(format: "%.1f", x) }

/// The frame account of a measurement window (the experiments' rule):
/// gaps between consecutive display-link timestamps, the window's edges
/// included so a main thread held across the whole window shows as one long
/// gap; a gap longer than 1.5 nominal intervals is a drop, and it missed
/// round(gap / nominal) - 1 frames.
public struct FrameAccount: Sendable, Equatable {
    public let frames: Int
    public let nominalHz: Double
    public let deliveredHz: Double
    public let drops: Int
    public let missed: Int
    public let expected: Int
    public let gapP50Ms: Double
    public let gapP99Ms: Double
    public let gapMaxMs: Double

    /// `timestamps` in seconds within [start, end]; `nominalHz` the
    /// display's rate.
    public init(timestamps: [Double], start: Double, end: Double, nominalHz: Double) {
        let nominal = 1 / nominalHz
        let points = [start] + timestamps + [end]
        var gaps: [Double] = []
        for i in 1..<points.count { gaps.append(points[i] - points[i - 1]) }
        let long = gaps.filter { $0 > 1.5 * nominal }
        frames = timestamps.count
        self.nominalHz = nominalHz
        deliveredHz = end > start ? Double(timestamps.count) / (end - start) : 0
        drops = long.count
        missed = long.reduce(0) { $0 + max(0, Int(($1 / nominal).rounded()) - 1) }
        expected = Int(((end - start) * nominalHz).rounded())
        let ms = gaps.map { $0 * 1000 }
        gapP50Ms = percentile(ms, 0.5)
        gapP99Ms = percentile(ms, 0.99)
        gapMaxMs = ms.max() ?? 0
    }
}
