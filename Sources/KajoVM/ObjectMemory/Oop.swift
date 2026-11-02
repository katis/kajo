/// An object-oriented pointer: a 64-bit tagged word.
///
/// Tag scheme (low bits):
///
///     ...xxx1  SmallInteger, 63-bit two's complement, value = raw >> 1
///     ...0000  object reference: the byte offset of its entry in the
///              entry table (entry index x 16); never 0
///     ...0010, ...0100, ...0110, ...1000, ...1010, ...1100, ...1110
///              reserved for future immediates (Character, SmallFloat64);
///              invalid today, rejected by the verifier and the loader
///     0        `Oop.none`: no object (an empty root, an unregistered
///              class); never stored in a heap slot
///
/// Nothing outside the object memory may treat a reference as anything but
/// an opaque identity (ADR 0003).
struct Oop: Hashable, Sendable, CustomStringConvertible {
    var raw: UInt64

    init(raw: UInt64) { self.raw = raw }

    static let none = Oop(raw: 0)

    // MARK: SmallInteger

    static let smallIntegerMax: Int64 = (1 << 62) - 1
    static let smallIntegerMin: Int64 = -(1 << 62)

    static func fitsSmallInteger(_ v: Int64) -> Bool {
        v >= smallIntegerMin && v <= smallIntegerMax
    }

    /// Traps when `v` does not fit; use `fitsSmallInteger` first where the
    /// value comes from arithmetic.
    init(smallInteger v: Int64) {
        precondition(Oop.fitsSmallInteger(v), "SmallInteger out of range")
        raw = UInt64(bitPattern: v &<< 1) | 1
    }

    var isSmallInteger: Bool { raw & 1 == 1 }

    /// Meaningful only when `isSmallInteger`.
    var smallIntegerValue: Int64 { Int64(bitPattern: raw) &>> 1 }

    // MARK: object references

    static let objectTagMask: UInt64 = 0xF

    init(entryIndex: UInt64) {
        precondition(entryIndex > 0 && entryIndex < 1 << 32, "entry index out of range")
        raw = entryIndex &<< 4
    }

    var isObject: Bool { raw & Oop.objectTagMask == 0 && raw != 0 }

    /// Meaningful only when `isObject`.
    var entryIndex: UInt64 { raw &>> 4 }

    /// A word that is neither a SmallInteger, an object reference nor
    /// `none`: a reserved immediate tag.
    var isReserved: Bool { raw & 1 == 0 && raw & Oop.objectTagMask != 0 }

    var description: String {
        if isSmallInteger { return "\(smallIntegerValue)" }
        if isObject { return "@\(entryIndex)" }
        if raw == 0 { return "none" }
        return "reserved(0x\(String(raw, radix: 16)))"
    }
}
