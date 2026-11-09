import Dispatch
import Foundation
import KajoApp
import KajoAppDevelopment
import KajoVM
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The first-launch follow-up (docs/modules/first-launch.md): where a gap
/// between two display-link callbacks of a scenario sits and what the main
/// thread was doing in it. Every gap over 100 ms from the link's start to
/// the window's end is a record: its position in the window, its length,
/// how late the callback that ended it ran (a callback due long ago that
/// ran just now: the main thread was held; one on time after a long gap:
/// the link delivered nothing), the last Smalltalk turn's end and the last
/// view call before it, and, when the launch traces (`kajo-launch-report`
/// or `trace=1`), a 10 ms main-queue heartbeat's longest silence and its
/// beats inside the gap (beats in a gap: the main thread was free and the
/// link was silent), and the system's notifications (activation, screens,
/// occlusion) with their times. Recorded in memory, written at the end.
@MainActor final class FrameGaps {
    struct Gap {
        let from: Double, to: Double  // display-link timestamps (uptime s)
        let callbackLateMs: Double
        let lastTurnEnd: UInt64, lastView: UInt64  // uptime ns, 0 for none
        let turnsIn: Int
        let beatsIn: Int, beatMaxSilenceMs: Double
        let active: Bool
        let wallAtEnd: Double, nowAtEnd: Double
        /// Still open when the window ended: no callback closed it.
        var open = false
    }

    nonisolated static let thresholdS = 0.1

    let tracing: Bool
    var gaps: [Gap] = []
    var events: [(name: String, now: Double, wall: Double)] = []
    var lastTs = 0.0
    var lastTurnEnd: UInt64 = 0
    var lastView: UInt64 = 0
    var turnsSinceTick = 0
    // the heartbeat
    var heartbeat: DispatchSourceTimer?
    var lastBeat: UInt64 = 0
    var beatsSinceTick = 0
    var maxSilenceSinceTick: UInt64 = 0
    var observers: [NSObjectProtocol] = []

    init(tracing: Bool) { self.tracing = tracing }

    /// At the link's start: the heartbeat and the notifications, when tracing.
    func start(window: AnyObject?) {
        guard tracing else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .nanoseconds(0))
        lastBeat = ShellVM.now()
        t.setEventHandler { [unowned self] in MainActor.assumeIsolated { self.beat() } }
        t.resume()
        heartbeat = t
        let nc = NotificationCenter.default
        #if os(macOS)
        let names: [(Notification.Name, String, NotificationCenter)] = [
            (NSApplication.didBecomeActiveNotification, "app-active", nc),
            (NSApplication.didResignActiveNotification, "app-resigned", nc),
            (NSApplication.didChangeScreenParametersNotification, "screen-parameters", nc),
            (NSApplication.didChangeOcclusionStateNotification, "app-occlusion", nc),
            (NSWindow.didChangeOcclusionStateNotification, "window-occlusion", nc),
            (NSWindow.didChangeScreenNotification, "window-screen", nc),
            (NSWorkspace.screensDidWakeNotification, "screens-wake", NSWorkspace.shared.notificationCenter),
            (NSWorkspace.screensDidSleepNotification, "screens-sleep", NSWorkspace.shared.notificationCenter),
            (NSWorkspace.didWakeNotification, "system-wake", NSWorkspace.shared.notificationCenter),
            (NSWorkspace.activeSpaceDidChangeNotification, "space", NSWorkspace.shared.notificationCenter),
        ]
        #else
        let names: [(Notification.Name, String, NotificationCenter)] = [
            (UIApplication.didBecomeActiveNotification, "app-active", nc),
            (UIApplication.willResignActiveNotification, "app-resigned", nc),
        ]
        #endif
        for (n, label, center) in names {
            observers.append(center.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.note(label) }
            })
        }
        note(appActive ? "active-at-link" : "inactive-at-link")
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        for o in observers { NotificationCenter.default.removeObserver(o); NSWorkspaceCenter.remove(o) }
        observers = []
    }

    func note(_ name: String) {
        events.append((name, Double(ShellVM.now()) / 1e9, Date().timeIntervalSince1970))
    }

    func beat() {
        let now = ShellVM.now()
        maxSilenceSinceTick = max(maxSilenceSinceTick, now &- lastBeat)
        lastBeat = now
        beatsSinceTick += 1
    }

    func turnEnded() { lastTurnEnd = ShellVM.now(); turnsSinceTick += 1 }
    func viewCalled() { lastView = ShellVM.now() }

    var appActive: Bool {
        #if os(macOS)
        NSApplication.shared.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    /// A display-link callback with timestamp `ts`, before its turn.
    func tick(_ ts: Double) {
        let nowNs = ShellVM.now()
        let now = Double(nowNs) / 1e9
        if lastTs > 0 && ts - lastTs > FrameGaps.thresholdS && gaps.count < 1000 {
            if tracing { maxSilenceSinceTick = max(maxSilenceSinceTick, nowNs &- lastBeat) }
            gaps.append(Gap(from: lastTs, to: ts, callbackLateMs: (now - ts) * 1000, lastTurnEnd: lastTurnEnd, lastView: lastView,
                            turnsIn: turnsSinceTick, beatsIn: beatsSinceTick, beatMaxSilenceMs: Double(maxSilenceSinceTick) / 1e6,
                            active: appActive, wallAtEnd: Date().timeIntervalSince1970, nowAtEnd: now))
        }
        lastTs = ts
        turnsSinceTick = 0
        beatsSinceTick = 0
        maxSilenceSinceTick = 0
    }

    /// At the window's end, before the link stops: a gap still open (no
    /// callback for over 100 ms) is recorded up to now, marked open.
    func finish() {
        let nowNs = ShellVM.now()
        let now = Double(nowNs) / 1e9
        guard lastTs > 0, now - lastTs > FrameGaps.thresholdS, gaps.count < 1000 else { return }
        if tracing { maxSilenceSinceTick = max(maxSilenceSinceTick, nowNs &- lastBeat) }
        var g = Gap(from: lastTs, to: now, callbackLateMs: 0, lastTurnEnd: lastTurnEnd, lastView: lastView,
                    turnsIn: turnsSinceTick, beatsIn: beatsSinceTick, beatMaxSilenceMs: Double(maxSilenceSinceTick) / 1e6,
                    active: appActive, wallAtEnd: Date().timeIntervalSince1970, nowAtEnd: now)
        g.open = true
        gaps.append(g)
    }

    /// One `trace gap` line per gap and one `trace event` line per
    /// notification; `start` and `end` are the window's (uptime s).
    func lines(windowStart start: Double, windowEnd end: Double) -> [String] {
        func ms(_ s: Double) -> String { f1(s * 1000) }
        func processMs(_ uptime: Double, _ wallAtNow: Double, _ now: Double) -> String {
            LaunchTrace.processMs(atWall: wallAtNow - (now - uptime)).map(f1) ?? "-"
        }
        var out: [String] = []
        for (i, g) in gaps.enumerated() {
            let whereIs = g.to <= start ? "before" : (g.from < start ? "start" : (g.from <= end ? "inside" : "after"))
            let ago = { (t: UInt64) -> String in t == 0 ? "-" : f1((g.from - Double(t) / 1e9) * 1000) }
            var l = "trace gap n=\(i + 1) where=\(whereIs) at_window_ms=\(ms(g.from - start)) ms=\(ms(g.to - g.from))"
            l += " process_ms=\(processMs(g.from, g.wallAtEnd, g.nowAtEnd)) callback_late_ms=\(f1(g.callbackLateMs))"
            l += " last_turn_end_before_ms=\(ago(g.lastTurnEnd)) last_view_before_ms=\(ago(g.lastView)) turns_in=\(g.turnsIn)"
            l += tracing ? " beats_in=\(g.beatsIn) beat_max_silence_ms=\(f1(g.beatMaxSilenceMs))" : ""
            l += " active=\(g.active ? 1 : 0) open=\(g.open ? 1 : 0)"
            out.append(l)
        }
        for e in events {
            out.append("trace event=\(e.name) at_window_ms=\(ms(e.now - start)) process_ms=\(LaunchTrace.processMs(atWall: e.wall).map(f1) ?? "-")")
        }
        return out
    }
}

/// Observers on the workspace's center are removed there (a no-op for the
/// others).
enum NSWorkspaceCenter {
    @MainActor static func remove(_ o: NSObjectProtocol) {
        #if os(macOS)
        NSWorkspace.shared.notificationCenter.removeObserver(o)
        #endif
    }
}

/// The gaps of a window's frame account over 100 ms: how many and where
/// the longest starts (ms from the window's start), for the result line.
func longGaps(_ timestamps: [Double], start: Double, end: Double) -> (count: Int, maxAtMs: Double) {
    let points = [start] + timestamps + [end]
    var n = 0, best = 0.0, at = 0.0
    for i in 1..<points.count {
        let g = points[i] - points[i - 1]
        if g > FrameGaps.thresholdS { n += 1 }
        if g > best { best = g; at = points[i - 1] - start }
    }
    return (n, at * 1000)
}
