/// The header word, kept in the object's entry (not in the body).
///
/// Layout, final for every collector module (experiments/concurrent-young
/// SPEC "Header word"):
///
///     bits  0..21  class index (0 is never a class: a free entry's header is 0)
///     bits 22..45  count: slots, or bytes for a byte object
///     bit  46      mark, full collection     reserved: module 1 marks in a side byte map
///     bit  47      byte object
///     bit  48      fired ephemeron: queued for finalization once, strong since
///     bits 49..51  unused                    reserved
///     bits 52..55  nursery index             young objects only (module 4)
///     bit  56      young                     module 4
///     bits 57..59  age: scavenges survived   young objects only (module 4)
///     bit  60      pinned for good: never moved
///     bit  61      frame pin: not moved by the current collection
///     bits 62..63  scavenge claim tag        young objects only (module 4)
///
/// Header bits are written only with the world stopped (or by the
/// allocating worker before the oop escapes); mutators never write a
/// header another thread reads (AGENTS.md). An old header has every
/// young-only bit clear: promotion clears them in the claim.
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
        | youngBit | youngOnlyMask
    /// Bits reserved for later modules (46, 49 to 51); zero in every header.
    static let reservedMask: UInt64 = ~usedMask

    static let maxClassIndex: UInt64 = classMask
    static let maxCount: UInt64 = (1 << countBits) - 1
    /// A body never spans a block: one word for the back reference, the rest
    /// for slots or bytes.
    static let maxSlots: Int = BlockHeap.blockBytes / 8 - 1
    static let maxBytes: Int = maxSlots * 8

    init(classIndex: UInt64, count: UInt64, isBytes: Bool) {
        precondition(classIndex <= Header.maxClassIndex && count <= Header.maxCount)
        raw = classIndex | count << Header.countShift | (isBytes ? Header.bytesBit : 0)
    }

    var classIndex: UInt64 { raw & Header.classMask }
    /// Slots, or bytes for a byte object.
    var count: UInt64 { (raw & Header.countMask) &>> Header.countShift }
    var isBytes: Bool { raw & Header.bytesBit != 0 }

    var isPinnedForGood: Bool {
        get { raw & Header.pinnedForGoodBit != 0 }
        set { raw = newValue ? raw | Header.pinnedForGoodBit : raw & ~Header.pinnedForGoodBit }
    }

    var isFramePinned: Bool {
        get { raw & Header.framePinBit != 0 }
        set { raw = newValue ? raw | Header.framePinBit : raw & ~Header.framePinBit }
    }

    var isPinned: Bool { raw & (Header.pinnedForGoodBit | Header.framePinBit) != 0 }

    var reservedBits: UInt64 { raw & Header.reservedMask }

    // MARK: young objects (module 4)

    var isYoung: Bool { raw & Header.youngBit != 0 }
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

    /// Body words: the back reference plus slots or byte words.
    var bodyWords: UInt64 {
        let n = count
        return 1 &+ (isBytes ? (n &+ 7) &>> 3 : n)
    }

    var bodyBytes: UInt64 { bodyWords &<< 3 }
}
