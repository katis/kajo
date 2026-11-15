// Symbol interning without a stop (docs/modules/symbol-interning.md): the
// suspected hole of the brief, the uniqueness, growth and re-interning
// tests, the method-cache test and the broken variants.

import Darwin
import Testing
@testable import KajoVM

let symbolInterningSrc = weakMarkingSrc + "\n" + """
method String asSymbol temps=0 prim=129
  push_nil
  return_top
end
method UndefinedObject internDrop: temps=0
  push_temp 0
  send asSymbol 0
  push_nil
  identical
  jump_if_false made
  push_int 1
  return_top
made:
  push_int 0
  return_top
end
"""

func internRuntime(_ src: String = symbolInterningSrc, background: Int = 1, _ change: (inout VMConfig) -> Void = { _ in }) throws -> Runtime {
    try Runtime(src, background: background, heapBlocks: 2048, start: false, configure: { c in
        c.nursery.bytes = 1024 * 1024
        c.nursery.age = 1
        c.marking.enabled = true
        c.marking.markerThread = false
        change(&c)
    })
}

extension Runtime {
    /// The host worker interns `s` by the slow path alone, as a worker
    /// whose lock-free lookup missed just before another worker's insert of
    /// the same bytes landed, and stores the answer into slot `i` of
    /// `holder` (a program's `H x: aString asSymbol`), holding it nowhere
    /// else.
    @discardableResult
    func internSlowInto(_ s: String, _ holder: Oop, _ i: Int) -> Oop {
        let str = vm.newString(s)
        return vm.host { w in
            let m = vm.machine(w)
            let sym = m.internSlow(str, m.om.byteObjectHash(str))
            if sym != .none { m.store(holder, i, sym, .instVarAtPut) }
            return sym
        }
    }
}

/// The brief's suspected hole: a worker's lookup misses, another worker
/// interns the same bytes and drops the Symbol, a scavenge with an initial
/// mark comes, and the first worker's second lookup (in the intern stop
/// before this module, under the lock since) finds the Symbol, a snapshot
/// entry held only by the bucket's weak slot, and hands it on. Stored into
/// an already scanned holder and dropped, it is swept under the holder
/// unless the second lookup keeps it alive.
private func secondLookupDuringMarking(keepAlive: Bool) throws -> (missed: UInt64, alive: Bool) {
    let rt = try internRuntime { c in c.testSwitches.internNoKeepAlive = !keepAlive }
    #expect(rt.runInt("internDrop:", oop: rt.vm.newString("zzHole")) == 0)  // made and dropped
    rt.run("mkWeakH")
    rt.scavenge()
    let h = rt.global(13)
    rt.vm.startCycle()
    _ = rt.vm.markStep(10_000_000)  // H, the table and the bucket scanned; the Symbol not marked
    let sym = rt.internSlowInto("zzHole", h, 0)  // the second lookup finds it
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    let missed = rt.marking.missed
    if missed > 0 {
        rt.stop(verifyHeap: false)
        return (missed, false)
    }
    rt.vm.sweep()
    rt.scavenge()
    let alive = rt.vm.inspect { $0.isUsedReference(sym) } && rt.slot(h, 0) == sym
    rt.stop(verifyHeap: alive)
    return (missed, alive)
}

@Test func aSymbolTheSecondLookupFindsDuringMarkingIsKeptAlive() throws {
    let (missed, alive) = try secondLookupDuringMarking(keepAlive: true)
    #expect(missed == 0 && alive, "missed \(missed)")
    let (missedOff, aliveOff) = try secondLookupDuringMarking(keepAlive: false)
    #expect(missedOff > 0 || !aliveOff)
    print("broken variant internNoKeepAlive: the final mark missed \(missedOff), the Symbol alive \(aliveOff)")
}

// MARK: - part 3: uniqueness, re-interning, growth, the cache, the variants

let internAllSrc = symbolInterningSrc + "\n" + """
; nil internAll: strings -- an Array of the Symbols of the Strings
method UndefinedObject internAll: temps=3
  push_temp 0
  size
  push_int 1
  add
  store_temp 1
  push_lit @Array
  push_temp 1
  push_int 1
  sub
  send new: 1
  store_temp 2
  push_int 1
  store_temp 3
top:
  push_temp 3
  push_temp 1
  lt
  jump_if_false done
  push_temp 2
  push_temp 3
  push_temp 0
  push_temp 3
  send at: 1
  send asSymbol 0
  send at:put: 2
  pop
  push_temp 3
  push_int 1
  add
  store_temp 3
  jump top
done:
  push_temp 2
  return_top
end
"""

/// `processes` Processes each intern `names` (each from its own Strings)
/// at once; answers each Process's Symbols, in `names` order.
private func internConcurrently(_ rt: Runtime, _ names: [String], processes: Int) -> [[Oop]] {
    let ps = (0..<processes).map { _ in rt.spawn("internAll:", [rt.vm.newStringArray(names)]) }
    rt.waitAllTerminated(600)
    let out = ps.map { p -> [Oop] in
        let a = rt.vm.result(of: p)
        return rt.vm.inspect { om in (0..<names.count).map { om.load(a, $0) } }
    }
    for p in ps { rt.vm.release(p) }
    return out
}

/// Every answer has the bytes asked for, and every pair of answers for
/// the same bytes is the same object. Answers the number of bytes that
/// came back as more than one Symbol.
private func duplicates(_ rt: Runtime, _ names: [String], _ answers: [[Oop]]) -> Int {
    var dup = 0
    let wrong = rt.vm.inspect { om -> [String] in
        var out: [String] = []
        for (i, name) in names.enumerated() {
            let set = Set(answers.map { $0[i] })
            if set.count > 1 { dup += 1 }
            for s in set where !(s.isObject && om.header(s).classIndex == WellKnown.symbol && om.sameBytes(s, Array(name.utf8))) {
                out.append(name)
            }
        }
        return out
    }
    #expect(wrong.isEmpty, "answers that are not the Symbol of their bytes: \(wrong.prefix(5))")
    return dup
}

func internSymbolsRuntime(background: Int = 7, noSecondLookup: Bool = false, marker: Bool = true, slowAllocation: Bool = false,
                          _ change: (inout VMConfig) -> Void = { _ in }) throws -> Runtime {
    try Runtime(internAllSrc, background: background, heapBlocks: 4096, configure: { c in
        c.verifySymbols = true
        c.marking.enabled = true
        c.marking.markerThread = marker
        c.testSwitches.internNoSecondLookup = noSecondLookup
        c.testSwitches.internSlowAllocation = slowAllocation
        change(&c)
    })
}

/// N workers intern the same bytes and different bytes at once (rule 1).
/// Rounds go on until the race was seen: a second lookup found a Symbol
/// another worker had inserted after this one's miss (`foundUnderLock`),
/// at most 40 rounds. Every answer for the same bytes is one object, and
/// the symbol-table verifier ran and found nothing.
@Test(arguments: [false, true])
func workersInterningTheSameBytesAtOnceGetOneSymbol(slowAllocation: Bool) throws {
    let rt = try internSymbolsRuntime(slowAllocation: slowAllocation)
    var round = 0
    repeat {
        let names = (0..<300).map { "u\(round)_\($0)" } + (0..<100).map { "v\(round)_\($0 % 7)_\($0)" }
        let answers = internConcurrently(rt, names, processes: 8)
        #expect(duplicates(rt, names, answers) == 0, "round \(round)")
        round += 1
    } while rt.vm.internCounters.foundUnderLock == 0 && round < 40
    let ic = rt.vm.internCounters
    #expect(ic.foundUnderLock > 0, "no round saw two workers race for the same bytes in \(round) rounds")
    if slowAllocation { #expect(ic.slowAllocations > 0 && ic.inserted > 0) }
    print("same bytes at once (slow allocation \(slowAllocation)): \(round) rounds, \(ic.inserted) inserted, \(ic.foundUnderLock) found under the lock, "
          + "\(ic.madeForNothing) made for nothing, \(ic.slowAllocations) made outside the lock, "
          + "\(rt.vm.counters[.internContended]) contended, longest hold \(ic.longestHoldNs) ns")
    _ = rt.vm.scavenge()
    #expect(rt.vm.internCounters.verifies > 0)
    #expect(rt.vm.counters[.symbolVerifierFailures] == 0, "\(rt.image.om.verifierReports.prefix(3))")
    #expect(rt.vm.counters[.internStops] == 0)
    rt.stop()
}

/// The broken variant: without the second lookup two workers that both
/// missed insert two Symbols of the same bytes; the duplicates come back to
/// the Processes and the symbol-table verifier reports them.
@Test func withoutTheSecondLookupTwoSymbolsOfTheSameBytesAppear() throws {
    let rt = try internSymbolsRuntime(noSecondLookup: true)
    var round = 0, dup = 0
    repeat {
        let names = (0..<300).map { "d\(round)_\($0)" }
        dup += duplicates(rt, names, internConcurrently(rt, names, processes: 8))
        round += 1
    } while dup == 0 && round < 40
    #expect(dup > 0, "no duplicate in \(round) rounds")
    _ = rt.vm.scavenge()
    print("broken variant internNoSecondLookup: \(dup) byte sequences answered by two Symbols in \(round) rounds; "
          + "\(rt.vm.counters[.symbolVerifierFailures]) verifier failures, first: \(rt.image.om.verifierReports.first ?? "-")")
    #expect(rt.vm.counters[.symbolVerifierFailures] > 0)
    #expect(rt.image.om.verifierReports.contains { $0.contains("two Symbols in the table") })
    rt.stop(verifyHeap: false)
}

/// Symbols dropped, collected and interned again across marking cycles:
/// odd rounds intern while a cycle marks (the keep-alive paths), even
/// rounds between cycles; every cycle frees the previous round's Symbols
/// (nothing holds them) and the next round makes new ones. Uniqueness
/// holds in every round and the verifiers find nothing.
@Test(arguments: [false, true])
func symbolsDroppedCollectedAndInternedAgainStayUnique(slowAllocation: Bool) throws {
    let rt = try internSymbolsRuntime(background: 3, marker: false, slowAllocation: slowAllocation)
    let names = (0..<200).map { "again\($0)" }
    var previous: [Oop] = []
    var renewed = 0
    for round in 0..<6 {
        if round % 2 == 1 { rt.vm.startCycle(); _ = rt.vm.markStep(1000) }
        let answers = internConcurrently(rt, names, processes: 4)
        #expect(duplicates(rt, names, answers) == 0, "round \(round)")
        if round % 2 == 1 { rt.finishCycle() } else { rt.vm.startCycle(); rt.finishCycle() }
        if !previous.isEmpty { renewed += zip(previous, answers[0]).filter { $0 != $1 }.count }
        previous = answers[0]
    }
    // Rounds after a cycle that freed the previous Symbols made new ones.
    #expect(renewed > 0)
    #expect(rt.marking.missed == 0)
    #expect(rt.vm.counters[.symbolVerifierFailures] == 0, "\(rt.image.om.verifierReports.prefix(3))")
    rt.stop()
}

/// A bucket grown through every size to 4095 Symbols, and the one past it:
/// primitive 129 fails (the method's fallback answers nil here; the
/// kernel's `asSymbol` reports `primitiveFailed`), a value and not a trap.
@Test func aBucketGrowsThroughEverySizeAndTheOnePastItIsRefused() throws {
    // The verifier runs once at the end, not at every stop of 4095 inserts
    // (O(Symbols) each: 369 s under the sanitizer with it on).
    let rt = try internSymbolsRuntime(background: 1, marker: false) { $0.verifySymbols = false }
    let table = rt.image.symbolTable
    func bucket(_ s: String) -> Int { Int(truncatingIfNeeded: utf8Hash(s.utf8)) & (SymbolTable.buckets - 1) }
    let b = bucket("fill0")
    let used = rt.vm.inspect { om -> Int in
        let k = om.load(table, b)
        return k == rt.image.nilObject ? 0 : (0..<Int(om.count(of: k))).filter { om.load(k, $0) != rt.image.nilObject }.count
    }
    let need = SymbolTable.maxBucket - used + 1
    // About 4 million candidates: hashed from a byte buffer, not Strings
    // (a debug build spent 30 s making them).
    var names: [String] = []
    var i = 0
    var buf: [UInt8] = Array("fill".utf8)
    while names.count < need {
        buf.removeSubrange(4...)
        var d = i, digits: [UInt8] = []
        repeat { digits.append(UInt8(48 + d % 10)); d /= 10 } while d > 0
        buf.append(contentsOf: digits.reversed())
        if Int(truncatingIfNeeded: utf8Hash(buf)) & (SymbolTable.buckets - 1) == b { names.append(String(decoding: buf, as: UTF8.self)) }
        i += 1
    }
    let growths0 = rt.vm.internCounters.growths
    let answers = internConcurrently(rt, names, processes: 1)[0]
    #expect(answers.dropLast().allSatisfy { $0 != rt.image.nilObject })
    #expect(answers.last == rt.image.nilObject, "the Symbol past a full bucket of 4095")
    let size = rt.vm.inspect { om in Int(om.count(of: om.load(table, b))) }
    #expect(size == SymbolTable.maxBucket)
    // 4, 8, ..., 2048, 4095 from wherever the bucket stood.
    #expect(rt.vm.internCounters.growths > growths0)
    let problems = rt.vm.inspect { $0.verifySymbolTable(table) }
    #expect(problems.isEmpty, "\(problems.prefix(3))")
    rt.stop()
}

let lookupCountSrc = internAllSrc + "\n" + """
method UndefinedObject lookup: temps=0 prim=135
  push_nil
  return_top
end
; nil countFound: aString times: n -- how many lookups found a Symbol
method UndefinedObject countFound:times: temps=2
  push_int 0
  store_temp 3
  push_int 0
  store_temp 2
top:
  push_temp 2
  push_temp 1
  lt
  jump_if_false done
  push_nil
  push_temp 0
  send lookup: 1
  push_nil
  identical
  jump_if_false hit
  jump next
hit:
  push_temp 3
  push_int 1
  add
  store_temp 3
next:
  push_temp 2
  push_int 1
  add
  store_temp 2
  jump top
done:
  push_temp 3
  return_top
end
"""

/// Rule 2: a lookup never reads a Symbol that is not whole. Readers look up
/// six NUL bytes, which no Symbol has, in the bucket where a seventh
/// Process inserts six other bytes. In the broken variant the insert stores
/// the Symbol before filling it and waits 20 ms between: a lock-free lookup
/// compares the zero fill and answers a Symbol for bytes nobody interned.
private func lookupsDuringAnInsert(publishBeforeFill: Bool) throws -> Int64 {
    let rt = try Runtime(lookupCountSrc, background: 7, heapBlocks: 4096, configure: { c in
        c.testSwitches.internPublishBeforeFill = publishBeforeFill
        c.testSwitches.internPauseUs = 20_000
    })
    func bucket(_ b: [UInt8]) -> Int { Int(truncatingIfNeeded: utf8Hash(b)) & (SymbolTable.buckets - 1) }
    let zeros = [UInt8](repeating: 0, count: 6)
    var i = 0
    while bucket(Array(String(format: "q%05d", i).utf8)) != bucket(zeros) { i += 1 }
    let name = String(format: "q%05d", i)
    let z = rt.vm.newString(String(decoding: zeros, as: UTF8.self))
    let readers = (0..<6).map { _ in rt.spawn("countFound:times:", [z, int(underThreadSanitizer ? 50_000 : 300_000)]) }
    usleep(5_000)
    let inserter = rt.spawn("internAll:", [rt.vm.newStringArray([name])])
    rt.waitAllTerminated(600)
    let found = readers.map { rt.result($0) }.reduce(0, +)
    for p in readers + [inserter] { rt.vm.release(p) }
    rt.stop(verifyHeap: !publishBeforeFill)
    return found
}

@Test func aLookupNeverReadsASymbolBeforeItIsWhole() throws {
    #expect(try lookupsDuringAnInsert(publishBeforeFill: false) == 0)
    // The broken variant is a data race by construction (bytes written
    // while readers compare them): skipped under the sanitizer only.
    if !underThreadSanitizer {
        let found = try lookupsDuringAnInsert(publishBeforeFill: true)
        #expect(found > 0)
        print("broken variant internPublishBeforeFill: \(found) lookups of six NUL bytes answered a Symbol")
    }
}

/// Rule 8, the method cache: a line names a selector by its entry. A
/// Symbol's entry is freed only by the old-space sweep, applied at a pause
/// every worker notes (each flushes its cache when it next looks), so no
/// line can name a freed and reused entry. A line is planted on worker 1
/// for a Symbol nothing holds; after the cycle that frees it, worker 1's
/// first slice has flushed the line, and the bytes interned again are a
/// new Symbol whose `perform:` does not find the planted method.
@Test func aSelectorCollectedAndInternedAgainFindsNoStaleLine() throws {
    let rt = try internRuntime(internAllSrc + "\n" + """
    method UndefinedObject zzPlanted temps=0
      push_int 66
      return_top
    end
    method Object perform: temps=0 prim=86
      push_int -2
      return_top
    end
    method UndefinedObject doesNotUnderstand: temps=0
      push_int -1
      return_top
    end
    method UndefinedObject performIt: temps=0
      push_nil
      push_temp 0
      send asSymbol 0
      send perform: 1
      return_top
    end
    """)
    #expect(rt.runInt("internDrop:", oop: rt.vm.newString("zzGone")) == 0)
    let goneString = rt.vm.newString("zzGone"), plantedString = rt.vm.newString("zzPlanted")
    let gone = rt.vm.host { w in rt.vm.machine(w).intern(goneString) }
    let planted = rt.vm.host { w -> Oop in
        let m = rt.vm.machine(w)
        let sel = m.intern(plantedString)
        return rt.image.lookup(classIndexOf(m.om, rt.image.nilObject.raw), sel) ?? .none
    }
    try #require(planted != .none)
    let line = rt.vm.host { _ -> Int in
        let w = rt.vm.state.worker(1)
        let cls = classIndexOf(rt.image.om, rt.image.nilObject.raw)
        let i = Int(truncatingIfNeeded: (gone.raw &>> 4) ^ cls) & (InterpreterState.cacheEntries - 1)
        w.pointee.interp.cache[i] = CacheEntry(classIndex: cls, selector: gone.raw, method: planted.raw)
        return i
    }
    rt.vm.startCycle()
    rt.finishCycle()
    #expect(rt.vm.inspect { !$0.isUsedReference(gone) || $0.header(gone).classIndex != WellKnown.symbol })
    #expect(rt.runInt("performIt:", oop: rt.vm.newString("zzGone")) == -1)  // not 66
    let still = rt.vm.host { _ in rt.vm.state.worker(1).pointee.interp.cache[line].selector == gone.raw }
    #expect(!still, "worker 1's line for the freed Symbol survived the pause")
    rt.stop()
}
