// Large bytes, part 1: the interpreter and the byte primitives over a byte
// object past the header's count field. `at:` and `at:put:` past 2^24 - 8
// fail the special send's bounds check (the count field is a sentinel no
// greater than the length) and the primitive answers from the true length;
// `size` asks the primitive. Every byte primitive over such an object polls
// between chunks of 256 KiB: the longest stretch of byte work a worker
// does between two polls is one chunk, counted in bytes (not time).

import Testing
@testable import KajoVM

private let n = Int(Header.longBytesFrom) + 1003

/// b := ByteArray new: n. b at: n put: 7; at: S + 1 put: 9. Answers
/// (b at: n) * 1000 + (b at: S + 1) * 10 + (b size = n) asBit.
private let indexing = """
  push_lit @ByteArray
  push_lit \(n)
  send new: 1
  store_temp 2
  push_temp 2
  push_lit \(n)
  push_int 7
  send at:put: 2
  pop
  push_temp 2
  push_lit \(Int(Header.longBytesFrom) + 1)
  push_int 9
  send at:put: 2
  pop
  push_temp 2
  push_lit \(n)
  send at: 1
  push_lit 1000
  mul
  push_temp 2
  push_lit \(Int(Header.longBytesFrom) + 1)
  send at: 1
  push_int 10
  mul
  add
  push_temp 2
  send size 0
  push_lit \(n)
  eq
  jump_if_false no
  push_int 1
  add
no:
  return_top
"""

@Test(arguments: [false, true])
func aLongByteArrayIsIndexedPastTheCountField(_ trustTheSentinel: Bool) throws {
    var sw = TestSwitches()
    sw.trustCountField = trustTheSentinel
    let src = runOf(indexing, temps: 1) + "method Object size temps=0 prim=95\n  push_nil\n  return_top\nend\n"
    let h = try Harness(src, base: ["prelude", "objectmodel"], heapBlocks: 2048, switches: sw)
    defer { h.destroy() }
    if trustTheSentinel {
        // The bounds check that trusts the sentinel refuses an index past
        // it: the primitive fails.
        #expect(h.error()?.kind == .primitiveFailed)
    } else {
        #expect(try h.value() == 7091)
    }
}

// MARK: - polled byte work in a running VM

/// Selectors for the primitives, on Object (any receiver), and the work: a
/// long ByteArray zeroed (`new:`), copied into another (38), made a String
/// (130: validated and copied), hashed (122), compared with a copy (121,
/// through `shallowCopy` 96), searched for a byte it does not hold (134)
/// and its scalars counted (126); answers the count, which is n.
private let workSource = """
method Object p38:a:a:a: temps=0 prim=38
  push_nil
  return_top
end
method Object p130 temps=0 prim=130
  push_nil
  return_top
end
method Object p122 temps=0 prim=122
  push_nil
  return_top
end
method Object p121: temps=0 prim=121
  push_nil
  return_top
end
method Object p96 temps=0 prim=96
  push_nil
  return_top
end
method Object p134:a: temps=0 prim=134
  push_nil
  return_top
end
method Object p126 temps=0 prim=126
  push_nil
  return_top
end
method UndefinedObject longWorkFast temps=4
  push_lit @ByteArray
  push_lit \(n)
  send new: 1
  store_temp 0
  push_temp 0
  push_lit \(n)
  push_int 65
  send at:put: 2
  pop
  push_temp 0
  send p96 0
  store_temp 1
  push_temp 1
  push_lit \(n)
  send at: 1
  push_lit \(n)
  add
  push_int 65
  sub
  return_top
end
method UndefinedObject longWork temps=4
  push_lit @ByteArray
  push_lit \(n)
  send new: 1
  store_temp 0
  push_lit @ByteArray
  push_lit \(n)
  send new: 1
  store_temp 1
  push_temp 0
  push_lit \(n)
  push_int 65
  send at:put: 2
  pop
  push_temp 1
  push_int 1
  push_lit \(n)
  push_temp 0
  push_int 1
  send p38:a:a:a: 4
  pop
  push_temp 1
  send p130 0
  store_temp 2
  push_temp 2
  send p122 0
  pop
  push_temp 2
  push_temp 2
  send p96 0
  send p121: 1
  jump_if_false bad
  push_temp 2
  push_lit 'x'
  push_int 1
  send p134:a: 2
  push_int 0
  eq
  jump_if_false bad
  push_temp 2
  send p126 0
  return_top
bad:
  push_int -1
  return_top
end
"""

/// Under ThreadSanitizer, whose every atomic byte load is instrumented,
/// the per-byte loops (validate, hash, search, count) of `longWork` take
/// minutes: `longWorkFast` fills one and copies it (`shallowCopy`) and
/// answers n from the copy's last byte.
private func runLongWork(polls: Bool) throws -> (Int64, ByteWorkCounters) {
    let rt = try Runtime(workSource, background: 1, heapBlocks: 8192, start: true, configure: { c in
        c.testSwitches.noBytePolls = !polls
    })
    let p = rt.spawn(underThreadSanitizer ? "longWorkFast" : "longWork")
    #expect(rt.waitAllTerminated(underThreadSanitizer ? 600 : 120))
    let v = rt.result(p)
    rt.vm.release(p)
    let c = rt.vm.byteWorkCounters
    rt.noFailures()
    rt.stop()
    return (v, c)
}

@Test func everyBytePrimitiveOverALongObjectPollsBetweenChunks() throws {
    let (v, c) = try runLongWork(polls: true)
    #expect(v == Int64(n))
    // Two fills, a copy, a validation and a copy, a hash, a copy and a
    // comparison, a search and a count: at least ten passes over n bytes
    // (under the sanitizer a fill and a copy: two).
    let passes = underThreadSanitizer ? 2 : 10
    #expect(c.bytes >= UInt64(passes * (n - ByteWork.chunk)), "\(c)")
    #expect(c.polls >= UInt64(passes * (n / ByteWork.chunk - 1)), "\(c)")
    #expect(c.longestStretch <= UInt64(ByteWork.chunk), "\(c)")
}

/// The broken variant: a long primitive that never lets a stop in. The
/// longest stretch between two polls is the whole run of byte work.
@Test func withoutPollsTheLongestStretchIsTheWholeWork() throws {
    let (v, c) = try runLongWork(polls: false)
    #expect(v == Int64(n))
    #expect(c.longestStretch >= UInt64(n), "\(c)")
}

// MARK: - collections speed: a ByteArray's equality and hash

private let m = 4 * ByteWork.chunk + 5

/// Two ByteArrays of four chunks and a bit (one a `shallowCopy` of the
/// other) compared (121) and hashed (122): 1 when equal with equal hashes.
/// Before the collections-speed module both primitives took text only and
/// failed here.
private let byteArraySource = workSource + "\n" + """
method UndefinedObject byteArrayWork temps=4
  push_lit @ByteArray
  push_lit \(m)
  send new: 1
  store_temp 0
  push_temp 0
  push_lit \(m)
  push_int 65
  send at:put: 2
  pop
  push_temp 0
  send p96 0
  store_temp 1
  push_temp 0
  push_temp 1
  send p121: 1
  jump_if_false bad
  push_temp 0
  send p122 0
  push_temp 1
  send p122 0
  eq
  jump_if_false bad
  push_int 1
  return_top
bad:
  push_int -1
  return_top
end
"""

/// Primitives 121 and 122 over a ByteArray past a chunk poll between
/// chunks as over a long String: the longest stretch of byte work between
/// two polls is one chunk.
@Test func aByteArrayPastAChunkIsComparedAndHashedPolled() throws {
    let rt = try Runtime(byteArraySource, background: 1, heapBlocks: 2048, start: true)
    let p = rt.spawn("byteArrayWork")
    #expect(rt.waitAllTerminated(underThreadSanitizer ? 600 : 120))
    let v = rt.result(p)
    rt.vm.release(p)
    let c = rt.vm.byteWorkCounters
    rt.noFailures()
    rt.stop()
    #expect(v == 1)
    // A comparison and two hashes of m bytes, each polled.
    #expect(c.bytes >= UInt64(3 * (m - ByteWork.chunk)), "\(c)")
    #expect(c.polls >= UInt64(3 * (m / ByteWork.chunk - 1)), "\(c)")
    #expect(c.longestStretch <= UInt64(ByteWork.chunk), "\(c)")
}
