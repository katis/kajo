import Dispatch
import Foundation
import QuartzCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// The native-by-default follow-up (docs/modules/native-by-default.md, part
// 1): the frames window of module 11a's round trip, moved here from the
// development half so a Release build reports frames too. A Debug build's
// `Development` runs it beside its server (with what the server served
// meanwhile); a Release build runs it from the launch, with nothing else.

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
        let ms = gaps.map { $0 * 1000 }.sorted()
        func rank(_ p: Double) -> Double { ms.isEmpty ? 0 : ms[min(ms.count - 1, Int((Double(ms.count - 1) * p).rounded()))] }
        gapP50Ms = rank(0.5)
        gapP99Ms = rank(0.99)
        gapMaxMs = ms.last ?? 0
    }
}

/// `kajo-frames=<seconds>` among the launch arguments: the display's frames
/// counted for that long after a second's warmup, one result line
/// (`mode=app run=frames build=<build> ... missed=... thermal=...`, then
/// `extra`'s fields), then the app quits. The frames are counted beside the
/// app, which runs as it always does.
@MainActor public final class FrameWindow: NSObject {
    /// The seconds `kajo-frames=` asks for, or nil.
    public nonisolated static func requested() -> Double? {
        CommandLine.arguments.first(where: { $0.hasPrefix("kajo-frames=") }).flatMap { Double($0.dropFirst(12)) }
    }

    let seconds: Double
    let build: String
    let extra: @MainActor () -> String
    var link: CADisplayLink?
    var times: [Double] = []
    var start = 0.0
    let nominal: Double
    var activity: NSObjectProtocol?

    /// `begin` runs when the window starts (after the warmup), `extra` when
    /// it ends; its text (` key=value`...) goes before `thermal=`.
    public init(seconds: Double, build: String, begin: @escaping @MainActor () -> Void = {},
                extra: @escaping @MainActor () -> String = { "" }) {
        self.seconds = seconds
        self.build = build
        self.extra = extra
        #if os(macOS)
        nominal = Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
        #else
        nominal = Double(UIScreen.main.maximumFramesPerSecond)
        #endif
        super.init()
        #if os(macOS)
        // The window is measured as a person would see it: the display
        // stays on and App Nap does not throttle the app's display link
        // while another app is in front of it.
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated, .latencyCritical],
                                                         reason: "Kajo frame measurement")
        AppKitHost.wakeDisplay()
        guard let l = NSScreen.main?.displayLink(target: self, selector: #selector(frame(_:))) else { return }
        #else
        // The screen stays on for the window (a locked screen has no frames).
        UIApplication.shared.isIdleTimerDisabled = true
        let l = CADisplayLink(target: self, selector: #selector(frame(_:)))
        #endif
        l.preferredFrameRateRange = CAFrameRateRange(minimum: Float(nominal), maximum: Float(nominal), preferred: Float(nominal))
        l.add(to: .main, forMode: .common)
        link = l
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                self.start = CACurrentMediaTime()
                begin()
                appLog("frames=start")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1 + seconds) { MainActor.assumeIsolated { self.end() } }
    }

    @objc func frame(_ l: CADisplayLink) {
        if start > 0 { times.append(l.timestamp) }
    }

    func end() {
        let stop = CACurrentMediaTime()
        link?.invalidate()
        let fa = FrameAccount(timestamps: times.filter { $0 >= start && $0 <= stop }, start: start, end: stop, nominalHz: nominal)
        func f3(_ x: Double) -> String { unsafe String(format: "%.3f", x) }
        func f2(_ x: Double) -> String { unsafe String(format: "%.2f", x) }
        appLog("mode=app run=frames build=\(build) seconds=\(f3(stop - start)) nominal_hz=\(f2(nominal)) frames=\(fa.frames) expected=\(fa.expected) missed=\(fa.missed) drops=\(fa.drops) gap_p99_ms=\(f3(fa.gapP99Ms)) gap_max_ms=\(f3(fa.gapMaxMs))\(extra()) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
        exit(0)
    }
}
