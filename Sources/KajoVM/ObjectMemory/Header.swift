/// The header word, kept in the object's entry (not in the body).
///
/// Layout, final for every collector module (experiments/concurrent-young
/// SPEC "Header word"):
///
///     bits  0..21  class index (0 is never a class: a free entry's header is 0)
///     bits 22..45  count: slots, or bytes for a byte object
///     bit  46      mark, full collection     reserved: module 1 marks in a side byte map
///     bit  47      byte object
///     bits 48..51  unused                    reserved
///     bits 52..55  nursery index             reserved for module 4
///     bit  56      young                     reserved for module 4
///     bits 57..59  age                       reserved for module 4
///     bit  60      pinned for good: never moved
///     bit  61      frame pin: not moved by the current collection
///     bits 62..63  scavenge claim tag        reserved for module 4
///
/// Header bits are written only with the world stopped; mutators never
/// write a header another thread reads (AGENTS.md).
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

    static let classMask: UInt64 = (1 << classBits) - 1
    static let countMask: UInt64 = ((1 << countBits) - 1) << countShift
    /// Bits this module defines and uses.
    static let usedMask: UInt64 = classMask | countMask | bytesBit | pinnedForGoodBit | framePinBit
    /// Bits reserved for later modules; zero in every header module 1 writes.
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

    /// Body words: the back reference plus slots or byte words.
    var bodyWords: UInt64 {
        let n = count
        return 1 &+ (isBytes ? (n &+ 7) &>> 3 : n)
    }

    var bodyBytes: UInt64 { bodyWords &<< 3 }
}
