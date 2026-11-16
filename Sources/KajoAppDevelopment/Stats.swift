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

// FrameAccount moved to KajoApp (Frames.swift) with the native-by-default
// follow-up: a Release build counts frames too.
