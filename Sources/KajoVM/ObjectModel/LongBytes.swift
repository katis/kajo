import Darwin
import Synchronization

// Large bytes (docs/modules/large-bytes.md, part 1): work over a byte
// object's bytes in chunks of `ByteWork.chunk` bytes with a poll between
// two chunks, so that no primitive over bytes keeps a stop waiting longer
// than one chunk of work. A gigabyte's fill, copy, compare or hash is tens
// to hundreds of milliseconds, during which every stop (and so the main
// thread) would otherwise wait for this worker.
//
// The poll parks for a requested stop and services module 7's rounds, as
// the interpreter's poll does, but never preempts: a primitive is not a
// resume point. The primitive's receiver and arguments are on its
// Process's stack (registers saved), so they are roots at the stop; a new
// object that only the primitive holds is a pending root while it polls.
// After a poll that parked, the primitive checks its objects' lengths
// again (a two-way become in that stop may have swapped a body under it)
// and fails if any changed. A chunk's addresses are computed from the
// entry each time: a long byte object is a run, which never moves, but no
// body pointer is kept across a poll.

/// The chunk of byte work between two polls, and its accounting.
enum ByteWork {
    /// 256 KiB: a memset or memcpy of it is about 10 to 25 µs, a per-byte
    /// loop (UTF-8, search) about 0.2 to 0.5 ms, on the devices too.
    static let chunk = 1 << 18
}

/// Per worker (the interpreter state's): the byte work done in polled
/// loops, the polls between chunks and those that parked, and the longest
/// stretch of byte work between two polls (the bound a test checks).
struct ByteWorkCounters: Sendable, Equatable {
    var chunks: UInt64 = 0
    var polls: UInt64 = 0
    var parks: UInt64 = 0
    var longestStretch: UInt64 = 0
    var bytes: UInt64 = 0
}

extension Machine {
    /// Between two chunks of byte work (`stretch` bytes since the last
    /// one): park for a requested stop and service module 7's rounds.
    /// Answers true when it parked or serviced a round, after which the
    /// caller checks its objects again. Out of line: one call per chunk.
    @inline(never)
    func byteWorkPoll(_ stretch: Int) -> Bool {
        let s = unsafe state
        unsafe s.pointee.byteWork.chunks &+= 1
        unsafe s.pointee.byteWork.bytes &+= UInt64(stretch)
        let st = UInt64(stretch) &+ (unsafe s.pointee.byteWorkUnpolled)
        let w = unsafe workerOf(s)
        guard let vm = unsafe w.pointee.vm, unsafe !vm.pointee.config.testSwitches.noBytePolls else {
            // The broken variant (and module 2's standalone interpreter): the
            // stretch goes on to the next poll.
            unsafe s.pointee.byteWorkUnpolled = st
            return false
        }
        if unsafe st > s.pointee.byteWork.longestStretch { unsafe s.pointee.byteWork.longestStretch = st }
        unsafe s.pointee.byteWorkUnpolled = 0
        unsafe s.pointee.byteWork.polls &+= 1
        let attention = unsafe s.pointee.safepointFlag.pointee.load(ordering: .relaxed)
        if attention == 0 { return false }
        // Holds no body pointer here (module 6's epoch rule).
        unsafe epochAdvance(vm, w)
        if attention & 1 != 0 { unsafe park(vm, w) }
        if attention > 1 { unsafe serviceRounds(vm, w) }
        unsafe s.pointee.byteWork.parks &+= 1
        return true
    }

    /// The end of a polled loop: its last stretch counts toward the
    /// longest (`stretch` bytes since the last poll).
    @inline(never)
    func byteWorkEnd(_ stretch: Int) {
        let s = unsafe state
        unsafe s.pointee.byteWork.bytes &+= UInt64(stretch)
        let st = UInt64(stretch) &+ (unsafe s.pointee.byteWorkUnpolled)
        unsafe s.pointee.byteWorkUnpolled = 0
        if unsafe st > s.pointee.byteWork.longestStretch { unsafe s.pointee.byteWork.longestStretch = st }
    }

    /// Zero a long byte object that `tryAllocateLarge` left unzeroed
    /// (`deferZero`): its bytes after the first word, in chunks. The object
    /// is a pending root while it polls (nothing else holds it yet), marked
    /// as being built so the instance walks (167 to 170) do not answer it
    /// half zeroed; with the pending table full it is zeroed without polls
    /// (counted). The review fixes (item 2, collectors.F1): after a poll
    /// that parked, the object's length and body are read again, and a
    /// change (a two-way become in that stop; unreachable while the walks
    /// skip it, kept as the other polled loops keep it) stops the zeroing,
    /// since whatever the object became is already whole. Every chunk is
    /// bounded by the length read after the poll, by `zeroBytes`' own check.
    func zeroLongBytes(_ o: Oop) {
        let om = self.om
        let words = om.bodyWords(entry: o.raw)
        let body = om.stateWord(o.raw)
        let total = Int(truncatingIfNeeded: words &- 1) &<< 3  // the byte words
        let w = unsafe workerOf(state)
        let vm = unsafe w.pointee.vm
        let h = unsafe vm.map { unsafe registerPending($0, o, building: true) } ?? -1
        var i = 8  // the first byte word was zeroed with the back reference
        var stretch = 0
        while i < total {
            let end = Swift.min(total, i &+ ByteWork.chunk)
            guard om.zeroBytes(o, from: i, to: end) else { break }
            stretch &+= end &- i
            i = end
            if i < total && h >= 0 {
                buildingPause()
                let parked = byteWorkPoll(stretch)
                stretch = 0
                if parked && (om.bodyWords(entry: o.raw) != words || om.stateWord(o.raw) != body) {
                    if let vm = unsafe vm { unsafe vm.count(.zeroingCutOff) }
                    break
                }
            }
        }
        byteWorkEnd(stretch)
        if h >= 0, let vm = unsafe vm { unsafe unregisterPending(vm, h) }
        if h < 0, let vm = unsafe vm { unsafe vm.count(.largeTriggersUnrooted) }
    }

    /// Copy `n` bytes of the byte object `src` from byte `i` into `dst`
    /// from byte `j` (ascending, no overlap that a forward copy would
    /// repeat), polling between chunks. Both runs (a copy longer than a
    /// chunk is only possible between two large objects): one `memmove` per
    /// chunk. Otherwise byte by byte through the entries, as before. False
    /// when a stop changed an object's length under it (the primitive
    /// fails).
    func copyBytesPolled(_ src: Oop, _ i: Int, into dst: Oop, _ j: Int, _ n: Int, building: Bool = false) -> Bool {
        let om = self.om
        if n <= ByteWork.chunk {
            copyBytes(src, i, into: dst, j, n)
            return true
        }
        let ls = om.count(of: src), ld = om.count(of: dst)
        var k = 0
        while k < n {
            let end = Swift.min(n, k &+ ByteWork.chunk)
            om.moveBytes(src, i &+ k, into: dst, j &+ k, end &- k)
            let stretch = end &- k
            k = end
            if k < n {
                if building { buildingPause() }
                if byteWorkPoll(stretch), om.count(of: src) != ls || om.count(of: dst) != ld { return false }
            } else {
                byteWorkEnd(stretch)
            }
        }
        return true
    }

    /// `body(lo, hi)` over [0, n) in chunks with a poll between; the
    /// objects `a` and `b` (b may be .none) must keep their lengths across
    /// a poll that parked. False when one changed (the primitive fails), or
    /// when `body` answers false (stop early).
    func overChunks(_ n: Int, _ a: Oop, _ b: Oop, _ body: (Int, Int) -> Bool) -> Bool {
        let om = self.om
        if n <= ByteWork.chunk { return body(0, n) }
        let la = om.count(of: a), lb = b == .none ? 0 : om.count(of: b)
        var k = 0
        while k < n {
            let end = Swift.min(n, k &+ ByteWork.chunk)
            if !body(k, end) {
                byteWorkEnd(end &- k)
                return false
            }
            let stretch = end &- k
            k = end
            if k < n {
                if byteWorkPoll(stretch), om.count(of: a) != la || (b != .none && om.count(of: b) != lb) { return false }
            } else {
                byteWorkEnd(stretch)
            }
        }
        return true
    }
}

extension ObjectMemory {
    /// Bytes [from, to) of the byte object `o` set to zero: one memset from
    /// the body the entry leads to now. A run's bytes only (never moved).
    /// False, writing nothing, unless `o` is a used large byte object whose
    /// byte words reach `to` now (the review fixes, item 2: a real check in
    /// every build, never an `assert`).
    func zeroBytes(_ o: Oop, from: Int, to: Int) -> Bool {
        guard from >= 8, from <= to, isUsedReference(o) else { return false }
        let h = header(o)
        guard h.isBytes, h.isLarge, to <= Int(truncatingIfNeeded: bodyWords(entry: o.raw) &- 1) &<< 3 else { return false }
        let off = Int(truncatingIfNeeded: stateWord(o.raw)) &+ 8 &+ from
        _ = unsafe memset(heapBase + off, 0, to &- from)
        return true
    }

    /// `n` bytes from `src` at `i` to `dst` at `j`, one memmove from the
    /// bodies the entries lead to now. Large objects only (runs never move;
    /// a smaller object could be relocated under a raw copy).
    func moveBytes(_ src: Oop, _ i: Int, into dst: Oop, _ j: Int, _ n: Int) {
        assert(header(src).isLarge && header(dst).isLarge && i + n <= Int(count(of: src)) && j + n <= Int(count(of: dst)))
        let so = Int(truncatingIfNeeded: stateWord(src.raw)) &+ 8 &+ i
        let d = Int(truncatingIfNeeded: stateWord(dst.raw)) &+ 8 &+ j
        _ = unsafe memmove(heapBase + d, heapBase + so, n)
    }
}

// MARK: - the byte primitives' long paths

extension Machine {
    /// A new object only this primitive holds stays a pending root while
    /// it polls, marked as being built (the instance walks skip it until it
    /// is whole: the review fixes, item 2, collectors.F4): the handle to release (negative: the table was full, and
    /// the caller must not poll).
    func holdPending(_ o: Oop) -> Int {
        guard let vm = unsafe workerOf(state).pointee.vm else { return -1 }
        return unsafe registerPending(vm, o, building: true)
    }

    func releasePending(_ h: Int) {
        guard h >= 0, let vm = unsafe workerOf(state).pointee.vm else { return }
        unsafe unregisterPending(vm, h)
    }

    /// A fresh byte object `dst` (held by nothing but this primitive) gets
    /// `n` bytes of `src` from `i` at `j`; polled when long, `dst` a pending
    /// root meanwhile (a full pending table copies unpolled, counted).
    func fillFresh(_ dst: Oop, _ j: Int, from src: Oop, _ i: Int, _ n: Int) -> Bool {
        if n <= ByteWork.chunk {
            copyBytes(src, i, into: dst, j, n)
            return true
        }
        let h = holdPending(dst)
        defer { releasePending(h) }
        if h < 0 {
            if let vm = unsafe workerOf(state).pointee.vm { unsafe vm.count(.largeTriggersUnrooted) }
            om.moveBytes(src, i, into: dst, j, n)
            byteWorkEnd(n)
            return true
        }
        return copyBytesPolled(src, i, into: dst, j, n, building: true)
    }

    /// The tests' `buildingPauseUs`: a sleep between two chunks of a
    /// polled primitive that builds a new object (never set outside tests).
    @inline(never)
    func buildingPause() {
        guard let vm = unsafe workerOf(state).pointee.vm else { return }
        let us = unsafe vm.pointee.config.testSwitches.buildingPauseUs
        if us > 0 { _ = usleep(UInt32(us)) }
    }

    /// Primitive 121 for long objects: nil when a stop changed a length.
    @inline(never)
    func sameBytesLong(_ a: Oop, _ b: Oop) -> Bool? {
        let n = Int(om.count(of: a))
        if n != Int(om.count(of: b)) { return false }
        var same = true
        let om = self.om
        let whole = overChunks(n, a, b) { lo, hi in
            same = om.compareBytes(a, lo, b, lo, hi &- lo) == 0
            return same
        }
        return whole || !same ? same : nil
    }

    /// Primitive 120 for long objects: -1, 0 or 1; nil when a stop changed
    /// a length.
    @inline(never)
    func compareBytesLong(_ a: Oop, _ b: Oop) -> Int64? {
        let la = Int(om.count(of: a)), lb = Int(om.count(of: b))
        var order = 0
        let om = self.om
        let whole = overChunks(Swift.min(la, lb), a, b) { lo, hi in
            order = om.compareBytes(a, lo, b, lo, hi &- lo)
            return order == 0
        }
        if order != 0 { return order < 0 ? -1 : 1 }
        if !whole { return nil }
        return la < lb ? -1 : la == lb ? 0 : 1
    }

    /// Primitive 122 for long objects (the same FNV-1a as
    /// `byteObjectHash`); nil when a stop changed the length.
    @inline(never)
    func byteHashLong(_ o: Oop) -> Int64? {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        let om = self.om
        let whole = overChunks(Int(om.count(of: o)), o, .none) { lo, hi in
            var i = lo
            while i < hi {
                h ^= UInt64(om.loadByte(o, i))
                h = h &* 0x0000_0100_0000_01B3
                i &+= 1
            }
            return true
        }
        return whole ? Int64(bitPattern: (h ^ (h &>> 62)) & 0x3FFF_FFFF_FFFF_FFFF) : nil
    }

    /// Primitive 126 for long objects; nil when a stop changed the length.
    @inline(never)
    func scalarCountLong(_ o: Oop) -> Int64? {
        var k: Int64 = 0
        let om = self.om
        let whole = overChunks(Int(om.count(of: o)), o, .none) { lo, hi in
            for i in lo..<hi where om.loadByte(o, i) & 0xC0 != 0x80 { k &+= 1 }
            return true
        }
        return whole ? k : nil
    }

    /// `isValidUTF8` for a long object, polling as the scalars pass each
    /// chunk; nil when a stop changed the length.
    @inline(never)
    func isValidUTF8Long(_ o: Oop) -> Bool? {
        let n = Int(om.count(of: o))
        var i = 0
        var mark = 0
        while i < n {
            guard let (_, len) = decodeScalar(n, i, { om.loadByte(o, $0) }) else {
                byteWorkEnd(i &- mark)
                return false
            }
            i &+= len
            if i &- mark >= ByteWork.chunk && i < n {
                if byteWorkPoll(i &- mark), Int(om.count(of: o)) != n { return nil }
                mark = i
            }
        }
        byteWorkEnd(i &- mark)
        return true
    }

    /// Primitive 134 for a long haystack or needle: the 1-based offset of
    /// the first match from `start`, 0 for none; every comparison counts as
    /// work and a poll comes after each chunk of it, inside one long
    /// comparison too. nil when a stop changed a length.
    @inline(never)
    func indexOfLong(_ r: Oop, _ needle: Oop, from start: Int) -> Int64? {
        let hay = Int(om.count(of: r)), k = Int(om.count(of: needle))
        var work = 0
        func pollIfDue() -> Bool {
            if work < ByteWork.chunk { return true }
            let w = work
            work = 0
            return !byteWorkPoll(w) || (Int(om.count(of: r)) == hay && Int(om.count(of: needle)) == k)
        }
        var i = start
        while i + k <= hay {
            var j = 0
            while j < k && om.loadByte(r, i &+ j) == om.loadByte(needle, j) {
                j &+= 1
                work &+= 1
                if work >= ByteWork.chunk && !pollIfDue() { return nil }
            }
            if j == k {
                byteWorkEnd(work)
                return Int64(i + 1)
            }
            work &+= 1
            if !pollIfDue() { return nil }
            i &+= 1
        }
        byteWorkEnd(work)
        return 0
    }
}

extension ObjectMemory {
    /// memcmp-style order of `n` bytes of `a` from `i` and `b` from `j`:
    /// one memcmp when both are large (runs never move), else byte by byte
    /// through the entries.
    func compareBytes(_ a: Oop, _ i: Int, _ b: Oop, _ j: Int, _ n: Int) -> Int {
        if header(a).isLarge && header(b).isLarge {
            let pa = Int(truncatingIfNeeded: stateWord(a.raw)) &+ 8 &+ i
            let pb = Int(truncatingIfNeeded: stateWord(b.raw)) &+ 8 &+ j
            return Int(unsafe memcmp(heapBase + pa, heapBase + pb, n))
        }
        var k = 0
        while k < n {
            let x = loadByte(a, i &+ k), y = loadByte(b, j &+ k)
            if x != y { return x < y ? -1 : 1 }
            k &+= 1
        }
        return 0
    }

    /// The bytes of a byte object copied out, nil for a long one (large
    /// bytes): a Swift copy of a gigabyte is not polled, so primitives
    /// that hand Smalltalk's bytes to Swift (host values, file writes,
    /// paths, numbers parsed from text) take only shorter ones.
    func bytesIfShort(of o: Oop) -> [UInt8]? {
        header(o).isLongBytes ? nil : bytes(of: o)
    }
}

// MARK: - primitive 38 over bytes

/// Large bytes: primitive 38, `replaceFrom: start to: stop with: source
/// startingAt: from`, for a byte receiver (not a String or Symbol: their
/// bytes stay valid UTF-8) and a byte source. Until now it failed for
/// bytes and the kernel's loop ran `at:put:` per byte. The bounds are
/// checked one by one before any arithmetic (collectors review, finding
/// 2). Ascending order as the kernel's loop: a copy within one object whose
/// target lies after its source and overlaps it would repeat bytes, so it
/// fails and the loop runs. A copy of a chunk or less goes byte by byte
/// with the post-store check (the receiver may be an old object the
/// relocator moves); a longer one is between two runs, which never move:
/// one memmove per chunk with a poll between.
@inline(never)
func primReplaceBytes(_ m: Machine, _ c: PrimitiveCall) -> Oop {
    let om = m.om
    let rcv = c.receiver, src = m.argument(2, of: c), startO = c.arg0, stopO = c.arg1, fromO = m.argument(3, of: c)
    guard startO.isSmallInteger, stopO.isSmallInteger, fromO.isSmallInteger, !m.isText(rcv) else { return .none }
    if om.isReadOnly(rcv) { return m.refuseReadOnly(rcv, at: startO, value: src) }
    let start = startO.smallIntegerValue, stop = stopO.smallIntegerValue, from = fromO.smallIntegerValue
    let rcount = Int64(om.count(of: rcv)), scount = Int64(om.count(of: src))
    guard start >= 1, start <= rcount + 1, stop >= start - 1, stop <= rcount else { return .none }
    let n = stop - start + 1
    if n == 0 { return rcv }
    guard from >= 1, from <= scount - n + 1 else { return .none }
    if rcv == src && start > from && start <= from + n - 1 { return .none }
    let i = Int(from - 1), j = Int(start - 1), k = Int(n)
    if k <= ByteWork.chunk {
        let st = unsafe m.state
        for x in 0..<k { unsafe checkedStoreByte(st, rcv, j &+ x, om.loadByte(src, i &+ x)) }
        return rcv
    }
    return m.copyBytesPolled(src, i, into: rcv, j, k) ? rcv : .none
}
