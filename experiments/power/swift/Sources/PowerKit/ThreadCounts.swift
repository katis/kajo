// Per-thread CPU time, cycles, instructions and energy split by core type,
// from proc_pidinfo(PROC_PIDTHREADCOUNTS = 34), a flavor not in the public
// SDK headers (xnu's proc_info_private.h): for a 64-bit thread id it fills
// one record per performance level, level 0 = performance cores. Used to
// give the collector's and the marker's P-core share and energy (SPEC.md
// "Telemetry"). If the call fails the fields read `tc_ok=0` and the P-core
// share falls back to the per-process figure.

import Darwin

@_silgen_name("proc_pidinfo")
private func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

public struct LevelCounts: Sendable, Equatable {
    public var instr: UInt64 = 0
    public var cycles: UInt64 = 0
    public var cpuNs: UInt64 = 0
    public var energyNj: UInt64 = 0
    public init() {}
}

public struct ThreadCounts: Sendable, Equatable {
    public var ok = false
    public var levels: [LevelCounts] = []
    public init() {}

    public var p: LevelCounts { levels.first ?? LevelCounts() }
    public var e: LevelCounts {
        var s = LevelCounts()
        for l in levels.dropFirst() {
            s.instr &+= l.instr; s.cycles &+= l.cycles; s.cpuNs &+= l.cpuNs; s.energyNj &+= l.energyNj
        }
        return s
    }

    public static func of(_ tid: UInt64, levels n: Int = 2) -> ThreadCounts {
        let recWords = 5
        let bytes = 8 + n * recWords * 8
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        defer { buf.deallocate() }
        memset(buf, 0, bytes)
        let r = proc_pidinfo(getpid(), 34, tid, buf, Int32(bytes))
        var out = ThreadCounts()
        guard r > 8 else { return out }
        let got = min(n, (Int(r) - 8) / (recWords * 8))
        let tb = ProcUsage.timebase
        for i in 0..<got {
            let w = buf.advanced(by: 8 + i * recWords * 8).assumingMemoryBound(to: UInt64.self)
            var l = LevelCounts()
            l.instr = w[0]; l.cycles = w[1]
            l.cpuNs = (w[2] &+ w[3]) &* UInt64(tb.numer) / UInt64(tb.denom)
            l.energyNj = w[4]
            out.levels.append(l)
        }
        out.ok = got > 0
        return out
    }

    /// Sum over threads.
    public static func sum(_ xs: [ThreadCounts]) -> ThreadCounts {
        var o = ThreadCounts()
        o.ok = !xs.isEmpty && xs.allSatisfy { $0.ok }
        let n = xs.map { $0.levels.count }.max() ?? 0
        o.levels = Array(repeating: LevelCounts(), count: n)
        for x in xs {
            for (i, l) in x.levels.enumerated() {
                o.levels[i].instr &+= l.instr; o.levels[i].cycles &+= l.cycles
                o.levels[i].cpuNs &+= l.cpuNs; o.levels[i].energyNj &+= l.energyNj
            }
        }
        return o
    }

    /// b - a, level by level.
    public static func delta(_ a: ThreadCounts, _ b: ThreadCounts) -> ThreadCounts {
        var o = ThreadCounts()
        o.ok = a.ok && b.ok
        for i in 0..<b.levels.count {
            let x = i < a.levels.count ? a.levels[i] : LevelCounts()
            var l = LevelCounts()
            l.instr = b.levels[i].instr &- x.instr; l.cycles = b.levels[i].cycles &- x.cycles
            l.cpuNs = b.levels[i].cpuNs &- x.cpuNs; l.energyNj = b.levels[i].energyNj &- x.energyNj
            o.levels.append(l)
        }
        return o
    }

    /// key=value fields with a prefix: CPU ms, P share, energy mJ (total and P).
    public func fields(_ k: String) -> String {
        let pc = p.cpuNs, ec = e.cpuNs, tot = pc &+ ec
        func r(_ x: Double, _ d: Double = 10) -> String { "\((x * d).rounded() / d)" }
        return " \(k)_tc_ok=\(ok ? 1 : 0) \(k)_cpu_ms=\(r(Double(tot) / 1e6)) \(k)_p_frac=\(r(tot > 0 ? Double(pc) / Double(tot) : 0, 1000))"
            + " \(k)_energy_mj=\(r(Double(p.energyNj &+ e.energyNj) / 1e6)) \(k)_penergy_mj=\(r(Double(p.energyNj) / 1e6))"
            + " \(k)_ipc=\(r((p.cycles &+ e.cycles) > 0 ? Double(p.instr &+ e.instr) / Double(p.cycles &+ e.cycles) : 0, 100))"
    }
}
