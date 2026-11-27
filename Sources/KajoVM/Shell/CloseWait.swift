import Darwin
import Foundation

// Gate reliability (docs/modules/gate-reliability.md): the close's wait for
// every Process to end, on the closing thread only, and the report of the
// Processes it waits for. No VM thread waits here: the closing thread wakes
// on the scheduler's done condition (broadcast by the last termination) or
// at its own short timeout to read the progress, so idle VM threads still
// wait untimed.

/// One live Process as the close saw it: no oop crosses it.
public struct ShellLiveProcess: Sendable, Equatable, CustomStringConvertible {
    public let id: Int64
    /// `ready`, `running`, `waiting` (or `state<n>` for any other value).
    public let state: String
    public let priority: Int
    /// The Process runs on the main worker only.
    public let mainAffine: Bool
    /// The worker running it, -1 when none.
    public let runningOn: Int
    public let terminateRequested: Bool
    /// The class of what it waits on (a Semaphore's), or nil.
    public let waitingOn: String?
    /// Its frames, innermost first, as `Class>>selector`, at most eight.
    public let frames: [String]

    public var description: String {
        "process \(id) \(state) priority=\(priority)\(mainAffine ? " main" : "") runningOn=\(runningOn)"
            + (terminateRequested ? " terminateRequested" : "") + (waitingOn.map { " waitingOn=\($0)" } ?? "")
            + " frames=[\(frames.joined(separator: " < "))]"
    }
}

extension VM {
    /// The terminations so far (the close's progress word).
    var terminationCount: UInt64 { unsafe state.pointee.counters[Counter.terminations.rawValue].load(ordering: .relaxed) }

    /// Every live Process, read inside the VM (as a primitive reads) under
    /// the scheduler lock: id, state, priority, affinity, the worker running
    /// it, whether a termination is requested, what it waits on and its top
    /// frames. A running Process's frames are its worker's and are not read.
    func liveProcesses(frames depth: Int = 8) -> [ShellLiveProcess] {
        unsafe host { _ in
            let om = image.om
            unsafe schedLock(state)
            defer { unsafe schedUnlock(state) }
            var out: [ShellLiveProcess] = []
            for ri in unsafe 0..<state.pointee.sched.pointee.recordHighWater {
                let r = unsafe records(state, ri)
                let p = unsafe r.pointee.process
                if p == .none { continue }
                let st = om.load(p, ProcessLayout.state).smallIntegerValue
                let name: String = switch ProcessState(rawValue: st) {
                case .ready: "ready"
                case .running: "running"
                case .waiting: "waiting"
                case .terminated: "terminated"
                case nil: "state\(st)"
                }
                let sem = om.load(p, ProcessLayout.waitingOn)
                let waitingOn = sem.isObject && sem != image.nilObject ? image.className(classIndexOf(om, sem.raw)) ?? "?" : nil
                var fs: [String] = []
                if unsafe r.pointee.runningOn < 0, let base = unsafe r.pointee.base, let end = unsafe r.pointee.end {
                    let words = unsafe end - base
                    if intSlot(om, p, ProcessLayout.pc) < 0 {
                        // Not started: word 0 holds the method.
                        fs.append(image.methodName(unsafe Oop(raw: base[0])).map { $0 + " (not started)" } ?? "?")
                    } else {
                        var hdr = intSlot(om, p, ProcessLayout.hdr)
                        while fs.count < depth && hdr > 0 && hdr + Frame.callerHdr < words {
                            fs.append(image.methodName(unsafe Oop(raw: base[hdr + Frame.method])) ?? "?")
                            if unsafe base[hdr + Frame.callerFP] == Frame.hostFP { break }
                            hdr = untagged(unsafe base[hdr + Frame.callerHdr])
                        }
                    }
                }
                out.append(unsafe ShellLiveProcess(
                    id: om.load(p, ProcessLayout.id).smallIntegerValue, state: name,
                    priority: intSlot(om, p, ProcessLayout.priority),
                    mainAffine: intSlot(om, p, ProcessLayout.affinity) == Affinity.main,
                    runningOn: r.pointee.runningOn, terminateRequested: r.pointee.terminateRequested,
                    waitingOn: waitingOn, frames: fs))
            }
            return out
        }
    }

    /// Wait until no Process is alive, on the calling thread. Part 1 of gate
    /// reliability: the wait is as untimed as before; once nothing has ended
    /// for `quietNs` it prints the live Processes on stderr, once.
    func waitUntilAllTerminatedReporting(quietNs: UInt64) {
        var last = terminationCount, lastLive = liveProcessCount, lastChange = nanoseconds()
        var reported = false
        let t0 = lastChange
        while true {
            unsafe pthread_mutex_lock(state.pointee.schedLock)
            if unsafe state.pointee.sched.pointee.liveProcesses == 0 {
                unsafe pthread_mutex_unlock(state.pointee.schedLock)
                break
            }
            var ts = timespec(tv_sec: 0, tv_nsec: 20_000_000)
            _ = unsafe pthread_cond_timedwait_relative_np(state.pointee.doneCond, state.pointee.schedLock, &ts)
            unsafe pthread_mutex_unlock(state.pointee.schedLock)
            let n = nanoseconds(), t = terminationCount, live = liveProcessCount
            if t != last || live != lastLive { last = t; lastLive = live; lastChange = n }
            if !reported && n &- lastChange >= quietNs {
                reported = true
                let ps = liveProcesses()
                let text = "kajo-close-wait quiet=\(String(format: "%.1f", Double(n &- lastChange) / 1e9))s live=\(ps.count)\n"
                    + ps.map { "kajo-close-wait  \($0)\n" }.joined()
                FileHandle.standardError.write(Data(text.utf8))
            }
        }
        if ProcessInfo.processInfo.environment["KAJO_CLOSE_TRACE"] != nil {
            FileHandle.standardError.write(Data("kajo-close-trace waited=\(String(format: "%.1f", Double(nanoseconds() &- t0) / 1e6))ms\n".utf8))
        }
    }
}
