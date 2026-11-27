// The known faults, item 2 (docs/modules/known-faults.md): eight workers
// that each intern a million Symbols and drop them failed every `asSymbol`
// after 4.0 million on 7ba9643, with `cycles=0`: a Symbol is old at birth,
// and the table's 1024 buckets of at most 4095 slots filled with dead
// Symbols that no collection had niled. A bucket at its largest with no
// hole now stalls a background worker for the collector (resource
// `symbols`), and the main worker, a justified stall or a VM with no
// marker takes one full collection (cause `symbols`); the primitive fails
// only when the bucket is still full after that.
//
// The short reproduction: buckets of at most 4 slots (`symbolBucketMax`,
// not a broken variant), so 4096 Symbols fill the table where the real one
// takes four million. Its broken variant (`symbolFullFailsAtOnce`) is the
// starting commit's path: a full bucket fails the primitive at once.

import Darwin
import Testing
@testable import KajoVM

let symbolTableFullSrc = internAllSrc + "\n" + """
; nil internEach: strings -- interns every String of the Array and keeps
; none of the Symbols; answers how many failed
method UndefinedObject internEach: temps=2
  push_int 0
  store_temp 1
  push_int 1
  store_temp 2
top:
  push_temp 2
  push_temp 0
  size
  gt
  jump_if_true done
  push_nil
  push_temp 0
  push_temp 2
  send at: 1
  send internDrop: 1
  push_temp 1
  add
  store_temp 1
  push_temp 2
  push_int 1
  add
  store_temp 2
  jump top
done:
  push_temp 1
  return_top
end
"""

/// Processes each interning `perProcess` Strings of their own and dropping
/// the Symbols, in a table whose buckets hold at most 4 (capacity 4096):
/// answers the failures summed over the Processes, or nil when they did not
/// all end.
private func internAndDrop(_ rt: Runtime, processes: Int, perProcess: Int) -> Int64? {
    let ps = (0..<processes).map { i in
        rt.spawn("internEach:", [rt.vm.newStringArray((0..<perProcess).map { "kf\(i)_\($0)" })])
    }
    guard rt.waitAllTerminated(underThreadSanitizer ? 3000 : 600) else { return nil }
    let failed = ps.reduce(Int64(0)) { $0 + rt.vm.result(of: $1).smallIntegerValue }
    for p in ps { rt.vm.release(p) }
    return failed
}

private func fullTableRuntime(background: Int, marker: Bool, failAtOnce: Bool = false, heapBlocks: Int = 4096) throws -> Runtime {
    try Runtime(symbolTableFullSrc, background: background, heapBlocks: heapBlocks, configure: { c in
        c.marking.enabled = true
        c.marking.markerThread = marker
        c.testSwitches.symbolBucketMax = 4
        c.testSwitches.symbolFullFailsAtOnce = failAtOnce
    })
}

/// Eight Processes on seven background workers intern 16 000 Symbols in a
/// table that holds 4096: every one is interned. The buckets at their
/// largest made the workers stall for the collector (or, once a cycle had
/// justified a stall, fall back), never fail.
@Test func workersThatInternAndDropMoreSymbolsThanTheTableHoldsNeverFail() throws {
    let t0 = now()
    let rt = try fullTableRuntime(background: 7, marker: true)
    defer { rt.stop() }
    let failed = internAndDrop(rt, processes: 8, perProcess: 2000)
    let s = rt.vm.stallLog!, c = rt.vm.markingCounters
    print("symbol-table-full stalled: failed=\(failed.map(String.init) ?? "-") stallsSymbols=\(s.symbols.count) "
          + "justified=\(s.symbols.justified) fallbacksSymbols=\(c.fallbacksSymbols) unjustified=\(c.unjustifiedFallbacks) "
          + "inserted=\(rt.vm.internCounters.inserted) body=\(Double(now() - t0) / 1e9) s")
    #expect(failed == 0, "\(failed.map(String.init) ?? "the Processes did not end") asSymbol failed")
    #expect(s.symbols.count > 0, "no worker stalled for a hole in a full bucket")
    #expect(rt.vm.internCounters.inserted >= 16000)
    #expect(c.unjustifiedFallbacks == 0)
}

/// With no marker thread nothing can be waited for: each full bucket takes
/// one full collection, counted as a fallback of cause `symbols`.
@Test func withNoMarkerAFullBucketFallsBackToAFullCollection() throws {
    let rt = try fullTableRuntime(background: 3, marker: false)
    defer { rt.stop() }
    let failed = internAndDrop(rt, processes: 4, perProcess: 2000)
    let c = rt.vm.markingCounters
    print("symbol-table-full no marker: failed=\(failed.map(String.init) ?? "-") fallbacksSymbols=\(c.fallbacksSymbols) "
          + "noMarker=\(c.fallbacksNoMarker) collections=\(rt.image.om.counters.collections)")
    #expect(failed == 0)
    #expect(c.fallbacksSymbols > 0 && c.fallbacksNoMarker >= c.fallbacksSymbols)
    #expect(c.unjustifiedFallbacks == 0)
}

/// The broken variant, in the suite: a full bucket fails the primitive at
/// once (the starting commit's path). Interning fails.
@Test func brokenVariantAFullBucketFailsAtOnce() throws {
    let rt = try fullTableRuntime(background: 7, marker: true, failAtOnce: true)
    defer { rt.stop() }
    let failed = internAndDrop(rt, processes: 8, perProcess: 2000)
    print("symbol-table-full broken variant: failed=\(failed.map(String.init) ?? "-")")
    #expect((failed ?? 0) > 0, "the broken variant failed nothing")
}

/// Live Symbols past the table's room still fail, after one collection: a
/// full bucket of Symbols something holds is the table's real limit. Each
/// refused one costs a full collection (a small heap keeps them short).
@Test func liveSymbolsPastTheTablesRoomStillFail() throws {
    let rt = try fullTableRuntime(background: 3, marker: true, heapBlocks: 512)
    defer { rt.stop() }
    let names = (0..<2850).map { "live\($0)" }
    let p = rt.spawn("internAll:", [rt.vm.newStringArray(names)])
    #expect(rt.waitAllTerminated(underThreadSanitizer ? 3000 : 600))
    let a = rt.vm.result(of: p)
    let nils = rt.vm.inspect { om in (0..<names.count).filter { om.load(a, $0) == rt.image.nilObject }.count }
    print("symbol-table-full live: nil answers=\(nils) of \(names.count)")
    #expect(nils > 0 && nils < names.count)
    rt.vm.release(p)
}
