// The review fixes, part 2, item 2 (kernel.F7): one identifier rule for
// both compilers. The bootstrap's scanner (KajoCompiler's Syntax.swift)
// and the kernel's (Scanner>>isLetterAt:, through primitive 171) both ask
// this function, so a method the live system accepts is one the image
// build accepts, by construction, on whatever Unicode tables the host has.
//
//   171  Scanner class>>identifierClassOf: anInteger. 1 when the scalar
//        anInteger is a letter (ASCII A-Z, a-z, _, or a scalar the host's
//        Unicode tables call alphabetic): it starts an identifier and
//        continues one. 2 when it only continues one: an ASCII digit, or a
//        non-ASCII scalar with a numeric type that is not alphabetic. 0
//        otherwise, and for any integer that is not a scalar (negative,
//        past U+10FFFF, a surrogate). Fails for anything but a
//        SmallInteger.

/// What a scalar is to an identifier: 0 nothing, 1 a letter (starts and
/// continues), 2 continues only (a digit or another numeric scalar).
package enum IdentifierRule {
    package static func classify(_ v: UInt32) -> Int {
        if v < 0x80 {
            if (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 95 { return 1 }
            return v >= 48 && v <= 57 ? 2 : 0
        }
        guard let s = Unicode.Scalar(v) else { return 0 }
        if s.properties.isAlphabetic { return 1 }
        return s.properties.numericType != nil ? 2 : 0
    }

    package static func isLetter(_ v: UInt32) -> Bool { classify(v) == 1 }

    package static func continues(_ v: UInt32) -> Bool { classify(v) != 0 }
}

func identifierPrimitive(_ c: PrimitiveCall) -> Oop {
    guard c.argc == 1, c.arg0.isSmallInteger else { return .none }
    let v = c.arg0.smallIntegerValue
    guard v >= 0, v <= 0x10FFFF else { return Oop(smallInteger: 0) }
    return Oop(smallInteger: Int64(IdentifierRule.classify(UInt32(v))))
}
