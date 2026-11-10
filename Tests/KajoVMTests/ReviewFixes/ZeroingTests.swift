// The review fixes, item 2 (docs/modules/review-fixes.md; collectors.F1
// and F4 of docs/reviews/2026-11-10/collectors.md): a long ByteArray that
// `zeroLongBytes` is still zeroing between polls was reachable through
// primitive 167, and a two-way `become:` in one of its polls' stops turned
// the rest of the zeroing into a memset past another object's body.
//
// Two layers, each tested here: the instance walks skip objects a polled
// primitive is still building (pending roots marked so), and the zeroing
// reads its object's length and body again after a poll that parked and
// stops when they changed (every chunk bounded by a real check). The hunt
// below runs `ByteArray allInstances` in a loop on one worker while another
// allocates a long ByteArray whose zeroing sleeps between chunks
// (`buildingPauseUs`), and `become:`s the first long ByteArray it finds with
// an 8-byte one.

import Testing
@testable import KajoVM

private let longCount = Int(Header.longBytesFrom) + 1

private let zeroingSource = """
method Object p95 temps=0 prim=95
  push_nil
  return_top
end
method Object allOf:limit: temps=0 prim=167
  push_nil
  return_top
end
; global 1 := ByteArray new: longCount; global 2 := 1 (done)
method UndefinedObject allocLong temps=1
  push_lit @ByteArray
  push_lit \(longCount)
  send new: 1
  store_temp 0
  push_nil
  push_int 1
  push_temp 0
  send globalAt:put: 2
  pop
  push_nil
  push_int 2
  push_int 1
  send globalAt:put: 2
  pop
  push_int 1
  return_top
end
; hunt until allocLong is done (one last walk after): the first long
; ByteArray found is global 3, its size global 4, and it becomes an
; 8-byte ByteArray. Answers 1 when it found one, 0 otherwise.
method UndefinedObject hunt temps=5
again:
  push_nil
  push_int 2
  send globalAt: 1
  store_temp 4
  push_nil
  push_lit @ByteArray
  push_lit 100000
  send allOf:limit: 2
  store_temp 0
  push_temp 0
  send p95 0
  store_temp 2
  push_int 1
  store_temp 1
scan:
  push_temp 1
  push_temp 2
  le
  jump_if_false next
  push_temp 0
  push_temp 1
  send at: 1
  store_temp 3
  push_temp 3
  send p95 0
  push_lit \(longCount)
  ge
  jump_if_false skip
  push_nil
  push_int 3
  push_temp 3
  send globalAt:put: 2
  pop
  push_nil
  push_int 4
  push_temp 3
  send p95 0
  send globalAt:put: 2
  pop
  push_temp 3
  push_lit @ByteArray
  push_int 8
  send new: 1
  send become: 1
  pop
  push_int 1
  return_top
skip:
  push_temp 1
  push_int 1
  add
  store_temp 1
  jump scan
next:
  push_temp 4
  push_nil
  identical
  jump_if_false giveup
  jump again
giveup:
  push_int 0
  return_top
end
"""

private func huntWhileZeroing(seeBuilding: Bool) throws -> (found: Int64, cutOffs: UInt64, foundSize: Oop) {
    let rt = try Runtime(zeroingSource, background: 2, heapBlocks: 2048, start: true, configure: { c in
        c.testSwitches.buildingPauseUs = 3000
        c.testSwitches.walksSeeBuilding = seeBuilding
    })
    let hunter = rt.spawn("hunt")
    let allocator = rt.spawn("allocLong")
    #expect(rt.waitAllTerminated(underThreadSanitizer ? 600 : 120))
    let found = rt.result(hunter)
    #expect(rt.vm.error(of: allocator) == nil, "\(String(describing: rt.vm.error(of: allocator)))")
    let size = rt.global(4)
    rt.vm.release(hunter)
    rt.vm.release(allocator)
    let cutOffs = rt.vm.counters[.zeroingCutOff]
    rt.noFailures()
    rt.stop()
    return (found, cutOffs, size)
}

/// The walks never answer an object still being zeroed: the hunt finds the
/// long ByteArray only once it is whole, so the zeroing never meets a
/// changed object. On d78afcc this traps in `zeroBytes`' assert (debug) or
/// writes past the 8-byte body (release); the hand run is recorded in the
/// module doc.
@Test func aLongByteArrayBeingZeroedIsNotAnInstanceYet() throws {
    let r = try huntWhileZeroing(seeBuilding: false)
    #expect(r.found == 1)
    #expect(r.foundSize == Oop(smallInteger: Int64(longCount)))
    #expect(r.cutOffs == 0)
}

/// The broken variant (the walks answer objects being built): the hunt
/// finds the ByteArray mid-zeroing and becomes it; the zeroing sees its
/// object's length change after the poll and stops, and the heap verifies.
@Test func aZeroingWhoseObjectWasBecomeStops() throws {
    let r = try huntWhileZeroing(seeBuilding: true)
    #expect(r.found == 1)
    #expect(r.cutOffs >= 1, "the hunt did not land in the zeroing (cut-offs \(r.cutOffs))")
}

// collectors.F4: a String a polled primitive is filling (123's
// concatenation past a chunk) was visible to 167 half copied. The same
// mark keeps it out: the hunt below counts the 1 MiB Strings it finds
// whose last byte is still zero.

private let stringSize = 1 << 20

private let stringSource = """
method Object p95 temps=0 prim=95
  push_nil
  return_top
end
method Object p124: temps=0 prim=124
  push_nil
  return_top
end
method Object p76 temps=0 prim=76
  push_nil
  return_top
end
method Object p123: temps=0 prim=123
  push_nil
  return_top
end
method Object allOf:limit: temps=0 prim=167
  push_nil
  return_top
end
; 'ab' doubled 19 times (the last concatenation builds 1 MiB in 4 polled
; chunks); global 2 := 1 after
method UndefinedObject concat temps=2
  push_lit 'ab'
  store_temp 0
  push_int 19
  store_temp 1
again:
  push_temp 1
  push_int 0
  gt
  jump_if_false done
  push_temp 0
  push_temp 0
  send p123: 1
  store_temp 0
  push_temp 1
  push_int 1
  sub
  store_temp 1
  jump again
done:
  push_nil
  push_int 1
  push_temp 0
  send globalAt:put: 2
  pop
  push_nil
  push_int 2
  push_int 1
  send globalAt:put: 2
  pop
  push_int 1
  return_top
end
; walk String allInstances until concat is done (one last walk after);
; answer how many 1 MiB Strings were found with a zero last byte
method UndefinedObject huntStrings temps=6
  push_int 0
  store_temp 5
again:
  push_nil
  push_int 2
  send globalAt: 1
  store_temp 4
  push_nil
  push_lit @String
  push_lit 100000
  send allOf:limit: 2
  store_temp 0
  push_temp 0
  send p95 0
  store_temp 2
  push_int 1
  store_temp 1
scan:
  push_temp 1
  push_temp 2
  le
  jump_if_false next
  push_temp 0
  push_temp 1
  send at: 1
  store_temp 3
  push_temp 3
  send p95 0
  push_lit \(stringSize)
  eq
  jump_if_false skip
  push_temp 3
  push_lit \(stringSize)
  send p124: 1
  send p76 0
  push_int 0
  eq
  jump_if_false skip
  push_temp 5
  push_int 1
  add
  store_temp 5
skip:
  push_temp 1
  push_int 1
  add
  store_temp 1
  jump scan
next:
  push_temp 4
  push_nil
  identical
  jump_if_false finished
  jump again
finished:
  push_temp 5
  return_top
end
"""

private func huntWhileFilling(seeBuilding: Bool) throws -> Int64 {
    let rt = try Runtime(stringSource, background: 2, heapBlocks: 2048, start: true, configure: { c in
        c.testSwitches.buildingPauseUs = 20000
        c.testSwitches.walksSeeBuilding = seeBuilding
    })
    let hunter = rt.spawn("huntStrings")
    let filler = rt.spawn("concat")
    #expect(rt.waitAllTerminated(underThreadSanitizer ? 600 : 120))
    let partial = rt.result(hunter)
    #expect(rt.result(filler) == 1)
    rt.vm.release(hunter)
    rt.vm.release(filler)
    rt.noFailures()
    rt.stop()
    return partial
}

/// The walks never answer a String still being filled.
@Test func aStringBeingFilledIsNotAnInstanceYet() throws {
    #expect(try huntWhileFilling(seeBuilding: false) == 0)
}

/// The broken variant: the hunt meets the 1 MiB String half copied.
@Test func withoutTheMarkAStringIsSeenHalfFilled() throws {
    #expect(try huntWhileFilling(seeBuilding: true) >= 1)
}

// MARK: - item 11: test primitive 39

private let peekSource = """
method Object slowPeek: temps=0 prim=39
  push_int -1
  return_top
end
; (Array with: 7) slowPeek: 1
method UndefinedObject peek temps=1
  push_lit @Array
  push_int 1
  send new: 1
  store_temp 0
  push_temp 0
  push_int 1
  push_int 7
  send at:put: 2
  pop
  push_temp 0
  push_int 1
  send slowPeek: 1
  return_top
end
"""

/// The review fixes, item 11 (interpreter.F3): primitive 39 fails unless
/// a test turns it on (the method's fallback answers -1); on d78afcc it
/// answered the slot (7) in every VM.
@Test(arguments: [false, true])
func testPrimitive39RunsOnlyWhenATestAsks(_ on: Bool) throws {
    let rt = try Runtime(peekSource, background: 1, start: true, configure: { $0.testSwitches.slowPeek = on })
    let p = rt.spawn("peek")
    #expect(rt.waitAllTerminated(60))
    #expect(rt.result(p) == (on ? 7 : -1))
    rt.vm.release(p)
    rt.stop()
}
