// Litmus tests of the memory-model abstraction (MemoryModel.swift): the
// outcomes it allows and forbids for the classic two-thread shapes. These
// say what the model can and cannot find before any protocol runs on it.

import Testing
@testable import RelocationModel

enum LitmusOp {
    case store(address: Int, value: Int, Order)
    case load(address: Int, Order, register: Int)
}

/// Every final register file reachable when `threads` run interleaved with
/// every order of store-buffer drains.
func outcomes(_ threads: [[LitmusOp]], words: Int = 2) -> Set<[Int]> {
    struct S: Hashable { var memory: Memory; var pcs: [Int]; var registers: [Int] }
    var seen: Set<S> = []
    var finals: Set<[Int]> = []
    var stack = [S(memory: Memory(words: Array(repeating: 0, count: words), threads: threads.count),
                   pcs: Array(repeating: 0, count: threads.count), registers: [0, 0, 0, 0])]
    while let s = stack.popLast() {
        guard seen.insert(s).inserted else { continue }
        var moved = false
        for t in threads.indices {
            for i in s.memory.drainable(t) {
                var n = s
                _ = n.memory.drain(t, i)
                stack.append(n); moved = true
            }
            guard s.pcs[t] < threads[t].count else { continue }
            var n = s
            switch threads[t][s.pcs[t]] {
            case let .store(a, v, o):
                n.memory.store(t, a, v, o)
            case let .load(a, o, r):
                guard let v = s.memory.load(t, a, o) else { continue }
                n.registers[r] = v
            }
            n.pcs[t] += 1
            stack.append(n); moved = true
        }
        if !moved { finals.insert(s.registers) }
    }
    return finals
}

let x = 0, y = 1

@Suite struct MemoryModel {
    /// Store buffering (Dekker): both loads read 0 only if a load overtakes
    /// its thread's earlier store. Allowed for release/acquire, forbidden for
    /// seq_cst: the distinction the post-store check rests on.
    @Test func storeBufferingIsAllowedForReleaseAcquireOnly() {
        func sb(_ st: Order, _ ld: Order) -> Bool {
            outcomes([
                [.store(address: x, value: 1, st), .load(address: y, ld, register: 0)],
                [.store(address: y, value: 1, st), .load(address: x, ld, register: 1)],
            ]).contains([0, 0, 0, 0])
        }
        #expect(sb(.release, .acquire))
        #expect(sb(.seqCst, .acquire))   // acquire load overtakes a seq_cst store
        #expect(sb(.release, .seqCst))   // seq_cst load overtakes a release store
        #expect(!sb(.seqCst, .seqCst))
    }

    /// Message passing: a release store publishes earlier relaxed stores; a
    /// relaxed flag store does not.
    @Test func releasePublishesEarlierStores() {
        func mp(_ flag: Order) -> Bool {
            outcomes([
                [.store(address: x, value: 1, .relaxed), .store(address: y, value: 1, flag)],
                [.load(address: y, .acquire, register: 0), .load(address: x, .relaxed, register: 1)],
            ]).contains([1, 0, 0, 0])
        }
        #expect(!mp(.release))
        #expect(mp(.relaxed))
    }

    /// Coherence: two stores to one address are seen in program order.
    @Test func storesToOneAddressAreSeenInOrder() {
        let r = outcomes([
            [.store(address: x, value: 1, .relaxed), .store(address: x, value: 2, .relaxed)],
            [.load(address: x, .relaxed, register: 0), .load(address: x, .relaxed, register: 1)],
        ])
        #expect(!r.contains([2, 1, 0, 0]))
        #expect(r.contains([1, 2, 0, 0]))
    }

    /// A thread reads its own buffered store (store forwarding).
    @Test func aThreadReadsItsOwnBufferedStore() {
        let r = outcomes([[.store(address: x, value: 1, .relaxed), .load(address: x, .relaxed, register: 0)]])
        #expect(r == [[1, 0, 0, 0]])
    }

    /// Independent reads of independent writes: both readers agree on the
    /// order of two stores by different threads. The model is multicopy
    /// atomic, so this weak outcome (allowed by C++ for acquire, forbidden on
    /// ARMv8 and x86) is never produced: a limit, not a guarantee.
    @Test func theModelIsMulticopyAtomic() {
        let r = outcomes([
            [.store(address: 0, value: 1, .release)],
            [.store(address: 1, value: 1, .release)],
            [.load(address: 0, .acquire, register: 0), .load(address: 1, .acquire, register: 1)],
            [.load(address: 1, .acquire, register: 2), .load(address: 0, .acquire, register: 3)],
        ])
        #expect(!r.contains([1, 0, 1, 0]))
    }
}
