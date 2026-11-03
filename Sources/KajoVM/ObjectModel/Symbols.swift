/// Strings and Symbols as the VM sees them (ADR 0009 section 8): byte
/// objects of UTF-8. A Symbol is an interned String: one object per byte
/// sequence, found through the symbol table, a pointer object (an Array)
/// of a power-of-two capacity, open addressing on the bytes' hash, nil
/// empty, at most half full. Lookups read the table a slot at a time and
/// compare bytes; insertion (and growth) happens on the host before any VM
/// runs, or with the world stopped (`primIntern`), so a lookup never sees
/// a half-built table and two workers never intern the same bytes twice.
/// Module 8b: the table is weak (ADR 0009 section 8): its buckets are
/// WeakArrays, so a Symbol nothing else references is collected and its
/// slot becomes nil, a tombstone the next insertion into that bucket
/// reuses. A lookup scans its whole bucket (a hole is no end), and a Symbol
/// a lookup finds goes through the weak read barrier, so one found while a
/// marking cycle runs is kept alive (AGENTS.md: weak reads during marking).

/// FNV-1a over the bytes, folded to a non-negative SmallInteger. The hash
/// of a String and of the Symbol with the same bytes are the same.
@inline(__always)
func utf8Hash<S: Sequence>(_ bytes: S) -> Int64 where S.Element == UInt8 {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    for b in bytes {
        h ^= UInt64(b)
        h = h &* 0x0000_0100_0000_01B3
    }
    return Int64(bitPattern: (h ^ (h &>> 62)) & 0x3FFF_FFFF_FFFF_FFFF)
}

extension ObjectMemory {
    /// The bytes of a byte object, copied out (cold paths: the loader,
    /// names in errors, interning).
    func bytes(of o: Oop) -> [UInt8] {
        let n = Int(count(of: o))
        var out = [UInt8](repeating: 0, count: n)
        for i in 0..<n { out[i] = loadByte(o, i) }
        return out
    }

    func byteObjectHash(_ o: Oop) -> Int64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        let n = Int(count(of: o))
        var i = 0
        while i < n {
            h ^= UInt64(loadByte(o, i))
            h = h &* 0x0000_0100_0000_01B3
            i &+= 1
        }
        return Int64(bitPattern: (h ^ (h &>> 62)) & 0x3FFF_FFFF_FFFF_FFFF)
    }

    /// The byte objects `a` and `b` hold the same bytes.
    func sameBytes(_ a: Oop, _ b: Oop) -> Bool {
        let n = count(of: a)
        if n != count(of: b) { return false }
        var i = 0
        while i < Int(n) {
            if loadByte(a, i) != loadByte(b, i) { return false }
            i &+= 1
        }
        return true
    }

    func sameBytes(_ a: Oop, _ bytes: [UInt8]) -> Bool {
        if Int(count(of: a)) != bytes.count { return false }
        for i in 0..<bytes.count where loadByte(a, i) != bytes[i] { return false }
        return true
    }

    /// The Symbol in `table` with this hash for which `matches` holds, or
    /// `.none`. Holes (collected Symbols) are skipped.
    func symbolLookup(_ table: Oop, hash: Int64, matches: (Oop) -> Bool) -> Oop {
        symbolLookupSlot(table, hash: hash, matches: matches).symbol
    }

    /// The same, with the bucket and slot it was found in (for the weak
    /// read barrier).
    func symbolLookupSlot(_ table: Oop, hash: Int64, matches: (Oop) -> Bool) -> (symbol: Oop, bucket: Oop, slot: Int) {
        let bucket = load(table, Int(truncatingIfNeeded: hash) & (SymbolTable.buckets &- 1))
        let nilObj = nilObject
        if bucket == nilObj { return (.none, .none, 0) }
        let n = Int(count(of: bucket))
        var i = 0
        while i < n {
            let k = load(bucket, i)
            if k != nilObj && matches(k) { return (k, bucket, i) }
            i &+= 1
        }
        return (.none, .none, 0)
    }

    /// The bucket `symbol` goes into, and the slot in it; nil when the
    /// bucket must first be replaced by a larger one (`symbolBucketSize`).
    func symbolSlot(_ table: Oop, hash: Int64) -> (bucket: Oop, slot: Int)? {
        let b = load(table, Int(truncatingIfNeeded: hash) & (SymbolTable.buckets &- 1))
        if b == nilObject { return nil }
        let n = Int(count(of: b))
        for i in 0..<n where load(b, i) == nilObject { return (b, i) }
        return nil
    }

    /// Symbols in the table.
    func symbolCount(_ table: Oop) -> Int {
        let nilObj = nilObject
        var n = 0
        for j in 0..<SymbolTable.buckets {
            let b = load(table, j)
            if b == nilObj { continue }
            for i in 0..<Int(count(of: b)) where load(b, i) != nilObj { n += 1 }
        }
        return n
    }
}

/// The symbol table's shape: an Array of `buckets` slots, each nil or a
/// WeakArray of Symbols with nil where none is (never used, or collected).
/// A full bucket is replaced by one twice its size (the old one's symbols
/// copied over),
/// so a table holds about `buckets` x 4095 symbols and no object exceeds a
/// block.
enum SymbolTable {
    static let buckets = 1024
    static let firstBucket = 4
    static let maxBucket = 4095

    static func grownBucketSize(_ old: Int) -> Int? {
        if old >= maxBucket { return nil }
        return old == 0 ? firstBucket : min(2 * old, maxBucket)
    }
}
