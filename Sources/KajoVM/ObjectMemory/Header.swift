/// The header word, kept in the object's entry (not in the body).
///
/// Layout, final for every collector module (experiments/concurrent-young
/// SPEC "Header word"):
///
///     bits  0..21  class index (0 is never a class: a free entry's header is 0)
///     bits 22..45  count: slots, or bytes for a byte object (large bytes:
///                  a byte object of 16 777 208 bytes or more holds
///                  16 777 208 | its length's low three bits, and its
///                  length is in its back reference: `isLongBytes`)
///     bit  46      mark, full collection     reserved: module 1 marks in a side byte map
///     bit  47      byte object
///     bit  48      fired ephemeron: queued for finalization once, strong since
///     bit  49      deferred free             a dead young entry whose free its
///                                            nursery deferred (module 7)
///     bit  50      read-only (module 8, ADR 0009 section 9): every store
///                                            path refuses the object
///     bit  51      unused                    reserved
///     bits 52..55  nursery index             young objects only (module 4)
///     bit  56      young                     module 4
///     bits 57..59  age: scavenges survived   young objects only (module 4)
///     bit  60      pinned for good: never moved
///     bit  61      frame pin: not moved by the current collection
///     bits 62..63  scavenge claim tag        young objects only (module 4)
///
/// Header bits are written only with the world stopped, by the allocating
/// worker before the oop escapes, or (module 7) by the one collector of a
/// young object's nursery while mutators read it: a compare-and-swap that
/// changes only the young-only bits, so every header load is a relaxed
/// atomic load. Mutators never write a header another thread reads
/// (AGENTS.md). An old header has every young-only bit clear: promotion
/// clears them in the claim.
struct Header: Hashable, Sendable {
    var raw: UInt64

    init(raw: UInt64) { self.raw = raw }

    static let classBits: UInt64 = 22
    static let countShift: UInt64 = 22
    static let countBits: UInt64 = 24
    static let markBit: UInt64 = 1 << 46
    static let bytesBit: UInt64 = 1 << 47
    static let nurseryShift: UInt64 = 52
    static let youngBit: UInt64 = 1 << 56
    static let ageShift: UInt64 = 57
    static let pinnedForGoodBit: UInt64 = 1 << 60
    static let framePinBit: UInt64 = 1 << 61
    static let claimShift: UInt64 = 62
    static let firedBit: UInt64 = 1 << 48
    /// Module 7: a dead young entry whose free its nursery deferred
    /// (concurrent-young amendments 10 and 17): used, dead, in no young log,
    /// its slot count 0. Every verifier skips it by this bit.
    static let deferredBit: UInt64 = 1 << 49
    /// Module 8: the object is read-only (ADR 0009 section 9). Set and
    /// cleared by a primitive with one atomic or (not a plain store: module
    /// 7's young collector decides a young header with a compare-and-swap
    /// concurrently, and retries when this bit changed under it); read by
    /// every store path, never by the collectors.
    static let readOnlyBit: UInt64 = 1 << 50

    static let nurseryMask: UInt64 = 0xF << nurseryShift
    static let ageMask: UInt64 = 7 << ageShift
    static let claimMask: UInt64 = 3 << claimShift
    /// Bits that only a young header may have set.
    static let youngOnlyMask: UInt64 = nurseryMask | ageMask | claimMask
    /// Young and nursery index: one `eor` and one `tst` tell whether two
    /// headers are young in the same nursery (the barrier).
    static let youngNurseryMask: UInt64 = youngBit | nurseryMask
    static let maxNurseries = 16
    static let maxAge: UInt64 = 7

    static let classMask: UInt64 = (1 << classBits) - 1
    static let countMask: UInt64 = ((1 << countBits) - 1) << countShift
    /// Bits this module defines and uses.
    static let usedMask: UInt64 = classMask | countMask | bytesBit | pinnedForGoodBit | framePinBit | firedBit
        | youngBit | youngOnlyMask | deferredBit | readOnlyBit
    /// Bits reserved for later modules (46, 51); zero in every header.
    static let reservedMask: UInt64 = ~usedMask

    static let maxClassIndex: UInt64 = classMask
    static let maxCount: UInt64 = (1 << countBits) - 1
    /// The largest ordinary body, one block: one word for the back
    /// reference, the rest for slots or bytes. Larger objects (module 10)
    /// are runs of blocks, old at birth; these two are still the limit of
    /// everything that must fit one block (methods, literal frames, the
    /// bytecodes' operands, Contexts, eden allocation).
    static let maxSlots: Int = BlockHeap.blockBytes / 8 - 1
    static let maxBytes: Int = maxSlots * 8
    /// Module 10: the largest pointer object, by the count field: 16 777 215
    /// slots (128 MiB). Large bytes: still the largest pointer object; byte
    /// objects go to `maxByteLength`.
    static let maxLargeCount: Int = Int(maxCount)

    /// Large bytes: the count field of a byte object at or past this length
    /// (2^24 - 8, a multiple of 8) is a sentinel, `longBytesFrom | n & 7`,
    /// and its length comes from its back reference's words. Every byte
    /// object shorter than this keeps its exact length in the field, so
    /// the bounds check `i < count` stays the fast path: for a long object
    /// the field is at most its length, so the check never admits an index
    /// out of bounds, and only its failure (out of line already) asks for
    /// the true length.
    static let longBytesFrom: UInt64 = maxCount & ~7
    /// Large bytes: the longest byte object, 2 GiB - 1 bytes. A body is
    /// one run of blocks whose head's `used` is a UInt32 (4 GiB), the back
    /// reference counts words in 32 bits (32 GiB), and the heap, its
    /// reserve, the growth and the nursery region share one 4 GiB
    /// reservation: half of it is the most one object may ask for. The
    /// heap's size and the device's memory bound it first in practice.
    static let maxByteLength: Int = (1 << 31) - 1

    /// The count field of a byte object of `n` bytes.
    @inline(__always)
    static func countField(bytes n: UInt64) -> UInt64 { n >= longBytesFrom ? longBytesFrom | n & 7 : n }

    init(classIndex: UInt64, count: UInt64, isBytes: Bool) {
        precondition(classIndex <= Header.maxClassIndex && count <= Header.maxCount)
        raw = classIndex | count << Header.countShift | (isBytes ? Header.bytesBit : 0)
    }

    var classIndex: UInt64 { raw & Header.classMask }
    /// The count field: slots, or bytes for a byte object, except a long
    /// byte object's sentinel (`isLongBytes`; its length is
    /// `ObjectMemory.count(of:)`).
    var count: UInt64 { (raw & Header.countMask) &>> Header.countShift }
    var isBytes: Bool { raw & Header.bytesBit != 0 }

    /// Large bytes: a byte object of `longBytesFrom` bytes or more, whose
    /// count field is a sentinel. Always large (a run), old, never moved.
    var isLongBytes: Bool { raw & Header.bytesBit != 0 && count >= Header.longBytesFrom }

    /// Large bytes: a long byte object's length from its body's words (its
    /// back reference): the whole words but the back reference, less the
    /// padding the field's low three bits leave.
    @inline(__always)
    func longLength(words: UInt64) -> UInt64 {
        let full = (words &- 1) &<< 3
        let odd = count & 7
        return odd == 0 ? full : full &- 8 &+ odd
    }

    /// Large bytes: the back reference's words agree with this header:
    /// equal to `bodyWords` for every object but a long byte object, whose
    /// words must decode to a length from `longBytesFrom` to the limit.
    func agrees(words: UInt64) -> Bool {
        guard isLongBytes else { return words == bodyWords }
        guard words >= 2 && words <= UInt64(Header.maxByteLength / 8 + 2) else { return false }
        let n = longLength(words: words)
        return n >= Header.longBytesFrom && n <= UInt64(Header.maxByteLength)
    }

    /// Body words from the header and, for a long byte object, the back
    /// reference `br`.
    @inline(__always)
    func bodyWords(backRef br: UInt64) -> UInt64 { isLongBytes ? BackRef.words(br) : bodyWords }

    var isPinnedForGood: Bool {
        get { raw & Header.pinnedForGoodBit != 0 }
        set { raw = newValue ? raw | Header.pinnedForGoodBit : raw & ~Header.pinnedForGoodBit }
    }

    var isFramePinned: Bool {
        get { raw & Header.framePinBit != 0 }
        set { raw = newValue ? raw | Header.framePinBit : raw & ~Header.framePinBit }
    }

    var isReadOnly: Bool { raw & Header.readOnlyBit != 0 }

    var isPinned: Bool { raw & (Header.pinnedForGoodBit | Header.framePinBit) != 0 }

    var reservedBits: UInt64 { raw & Header.reservedMask }

    // MARK: young objects (module 4)

    var isYoung: Bool { raw & Header.youngBit != 0 }
    /// Module 7: a deferred entry free (see `deferredBit`).
    var isDeferredFree: Bool { raw & Header.deferredBit != 0 }
    /// Scavenges survived; young objects only.
    var age: UInt64 { (raw & Header.ageMask) &>> Header.ageShift }
    /// The nursery the body lies in; young objects only.
    var nurseryIndex: Int { Int(truncatingIfNeeded: (raw & Header.nurseryMask) &>> Header.nurseryShift) }
    /// The two claim-tag bits (bit 0 = header bit 62).
    var claimTag: UInt64 { (raw & Header.claimMask) &>> Header.claimShift }

    /// This header as a freshly allocated young object in nursery `n`.
    func youngIn(nursery n: Int) -> Header {
        Header(raw: raw & ~Header.youngOnlyMask | Header.youngBit | UInt64(n) &<< Header.nurseryShift)
    }

    /// An ephemeron already queued for finalization: traced as strong.
    var isFiredEphemeron: Bool {
        get { raw & Header.firedBit != 0 }
        set { raw = newValue ? raw | Header.firedBit : raw & ~Header.firedBit }
    }

    /// Body words: the back reference plus slots or byte words. Not for a
    /// long byte object, whose header does not hold its length: its
    /// readers use `bodyWords(backRef:)` or `ObjectMemory.bodyWords(entry:)`
    /// (large bytes; every reader is in docs/modules/large-bytes.md).
    var bodyWords: UInt64 {
        assert(!isLongBytes, "a long byte object's body words are in its back reference")
        let n = count
        return 1 &+ (isBytes ? (n &+ 7) &>> 3 : n)
    }

    var bodyBytes: UInt64 { bodyWords &<< 3 }

    /// Module 10: the body does not fit one block, so it is a run of blocks
    /// (the count test; no header bit marks it, since no hot path asks).
    /// A long byte object is always one.
    var isLarge: Bool { isLongBytes || bodyBytes > UInt64(BlockHeap.blockBytes) }
}
