/// An object-oriented pointer: a 64-bit tagged word.
///
/// Tag scheme (low bits):
///
///     ...xxx1  SmallInteger, 63-bit two's complement, value = raw >> 1
///     ...xx10  SmallFloat (module 8, ADR 0009 section 2): 62 bits of a
///              double with a 9-bit exponent (`SmallFloat` below)
///     ...0100  Character (module 8): a Unicode scalar in bits 4..63
///     ...0000  object reference: the byte offset of its entry in the
///              entry table (entry index x 16); never 0
///     ...1000, ...1100
///              spare: invalid, rejected by the verifier and the loaders
///     0        `Oop.none`: no object (an empty root, an unregistered
///              class); never stored in a heap slot
///
/// "Not a reference" is `raw & 0xF != 0` (`objectTagMask`), never
/// `raw & 1`: every site that decides whether a word names an entry tests
/// the full pattern (docs/modules/object-model.md has the inventory).
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

    /// Not a reference and not `none`: a SmallInteger, SmallFloat,
    /// Character or a spare pattern.
    var isImmediate: Bool { raw & Oop.objectTagMask != 0 }

    /// A word that is neither a valid immediate, an object reference nor
    /// `none`: a spare tag (`1000`, `1100`) or a Character whose payload is
    /// not a Unicode scalar.
    var isReserved: Bool { isImmediate && !isValidImmediate }

    /// SmallInteger, SmallFloat (every `..10` word decodes), or a Character
    /// holding a Unicode scalar.
    var isValidImmediate: Bool {
        isSmallInteger || isSmallFloat || (isCharacter && Oop.isScalar(raw &>> 4))
    }

    // MARK: Character (`0100`)

    static let characterTag: UInt64 = 0b0100

    var isCharacter: Bool { raw & Oop.objectTagMask == Oop.characterTag }

    static func isScalar(_ v: UInt64) -> Bool { v <= 0x10FFFF && !(0xD800...0xDFFF).contains(v) }

    /// Traps unless `scalar` is a Unicode scalar value.
    init(character scalar: UInt32) {
        precondition(Oop.isScalar(UInt64(scalar)), "not a Unicode scalar")
        raw = UInt64(scalar) &<< 4 | Oop.characterTag
    }

    /// Meaningful only when `isCharacter`.
    var characterValue: UInt32 { UInt32(truncatingIfNeeded: raw &>> 4) }

    // MARK: SmallFloat (`..10`)

    var isSmallFloat: Bool { raw & 3 == 2 }

    /// The SmallFloat for `d`, or nil when its exponent does not fit nine
    /// bits (NaN, infinities, subnormals, magnitudes outside about 1e-77 to
    /// 1e77, and exactly plus or minus 2^-255, whose pattern zero takes).
    init?(smallFloat d: Double) {
        guard let w = SmallFloat.encode(d.bitPattern) else { return nil }
        raw = w
    }

    /// Meaningful only when `isSmallFloat`.
    var smallFloatValue: Double { Double(bitPattern: SmallFloat.decode(raw)) }

    var description: String {
        if isSmallInteger { return "\(smallIntegerValue)" }
        if isObject { return "@\(entryIndex)" }
        if raw == 0 { return "none" }
        if isSmallFloat { return "\(smallFloatValue)" }
        if isCharacter && isValidImmediate { return "$U+\(String(characterValue, radix: 16))" }
        return "reserved(0x\(String(raw, radix: 16)))"
    }
}

/// The SmallFloat encoding (ADR 0009 section 2): a double rotated left by
/// one (sign to bit 0, exponent to bits 53..63), the exponent offset by
/// 768 so that biased exponents 768...1279 become 0...511 (nine bits), the
/// 62 bits shifted over the `10` tag. Zero is the rotated double itself
/// (0 or 1 for the sign); the one value that would collide with it, plus or
/// minus 2^-255, is boxed. Encoding is a rotate, a subtract and a compare;
/// decoding the reverse. Inline in the arithmetic paths; the boxed Float is
/// the out-of-line case.
enum SmallFloat {
    static let offset: UInt64 = 768 << 53

    @inline(__always)
    static func encode(_ bits: UInt64) -> UInt64? {
        let r = bits &<< 1 | bits &>> 63
        let x = r &- offset
        if x &- 2 < (1 << 62) &- 2 { return x &<< 2 | 2 }
        if r <= 1 { return r &<< 2 | 2 }
        return nil
    }

    @inline(__always)
    static func decode(_ raw: UInt64) -> UInt64 {
        let x = raw &>> 2
        let r = x <= 1 ? x : x &+ offset
        return r &>> 1 | r &<< 63
    }
}
