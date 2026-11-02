// Temporary instrumentation for DIAGNOSIS-parallel-scavenge.md step 4: a ring
// of events (mach_absolute_time, kind, worker, entry, extra), dumped for one
// entry when the mark verifier reports it. Removed after the diagnosis.

import Darwin
import Synchronization

enum DiagEv {
    static let initialMark: UInt64 = 1   // a = cycle
    static let finalMark: UInt64 = 2     // a = cycle
    static let deferPush: UInt64 = 3     // dead remembered holder deferred (a = idx, b = k)
    static let deferKept: UInt64 = 4     // deferred free postponed: rem re-armed (a = idx, b = rem word)
    static let deferFree: UInt64 = 5     // deferred entry freed (a = idx, b = k)
    static let reallocSnap: UInt64 = 6   // marking: a refill takes a snapshot entry (a = idx)
    static let ycFreeSnap: UInt64 = 7    // marking: a local sweep frees a snapshot entry (a = idx, b = k)
    static let names = ["", "initialMark", "finalMark", "deferPush", "deferKept", "deferFree", "reallocSnap", "ycFreeSnap"]
}

let diagCap = 1 << 20
nonisolated(unsafe) let diagRing = UnsafeMutablePointer<UInt64>.allocate(capacity: diagCap * 4)
nonisolated(unsafe) let diagNext = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
nonisolated(unsafe) let diagCounts = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 8)
private let diagInit: Bool = {
    diagNext.initialize(to: Atomic(0))
    for i in 0..<8 { (diagCounts + i).initialize(to: Atomic(0)) }
    return true
}()

@inline(never)
func diag(_ kind: UInt64, _ worker: Int, _ a: UInt64, _ b: UInt64 = 0) {
    _ = diagInit
    diagCounts[Int(kind)].wrappingAdd(1, ordering: .relaxed)
    let i = diagNext.pointee.wrappingAdd(1, ordering: .relaxed).oldValue & (diagCap - 1)
    let p = diagRing + i * 4
    p[0] = mach_absolute_time()
    p[1] = kind | (UInt64(bitPattern: Int64(worker)) &<< 8)
    p[2] = a
    p[3] = b
}

/// World stopped: every event naming entry `idx`, plus cycle events.
func diagDump(_ idx: Int) {
    _ = diagInit
    let n = min(diagNext.pointee.load(ordering: .relaxed), diagCap)
    var lines: [(UInt64, String)] = []
    for i in 0..<n {
        let p = diagRing + i * 4
        let k = p[1] & 0xff
        let w = Int64(bitPattern: p[1]) >> 8
        let isCycle = k == DiagEv.initialMark || k == DiagEv.finalMark
        if isCycle || Int(p[2]) == idx {
            lines.append((p[0], "  t=\(p[0]) \(DiagEv.names[Int(k)]) w=\(w) a=\(p[2]) b=\(p[3])"))
        }
    }
    lines.sort { $0.0 < $1.0 }
    var s = "diag: events for entry \(idx) (counts:"
    for k in 1..<8 { s += " \(DiagEv.names[k])=\(diagCounts[k].load(ordering: .relaxed))" }
    s += ")\n"
    for l in lines.suffix(40) { s += l.1 + "\n" }
    FileHandleStderr.write(s)
}
