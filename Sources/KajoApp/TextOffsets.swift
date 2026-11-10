import Foundation
import KajoVM

// Module 9c: what both shells' text views share (docs/modules/developer-ui.md,
// "The second round of view wrappers"). The image's positions in a String
// are 1-based UTF-8 byte offsets and a range is start to stop inclusive (an
// empty one at start has stop start - 1); AppKit's and UIKit's are UTF-16
// `NSRange`s. These convert between the two, read the image's style
// triples and name a key press the way the image binds keys (`cmd-s`).

public enum TextOffsets {
    /// The `NSRange` of bytes start...stop of `text`, or nil when they are
    /// not a range of it at scalar boundaries.
    public static func nsRange(_ text: String, start: Int, stop: Int) -> NSRange? {
        let u = text.utf8
        guard start >= 1, stop >= start - 1, stop <= u.count else { return nil }
        let a = u.index(u.startIndex, offsetBy: start - 1), b = u.index(u.startIndex, offsetBy: stop)
        guard a.samePosition(in: text.unicodeScalars) != nil, b.samePosition(in: text.unicodeScalars) != nil else { return nil }
        return NSRange(a..<b, in: text)
    }

    /// The image's {start. stop} of an `NSRange` of `text`.
    public static func byteRange(_ text: String, _ r: NSRange) -> (start: Int, stop: Int) {
        guard let range = Range(r, in: text) else { return (1, 0) }
        let start = text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound) + 1
        let length = text.utf8.distance(from: range.lowerBound, to: range.upperBound)
        return (start, start + length - 1)
    }

    /// A style the image names: `color:<name>`, `background:<name>`, `bold`.
    public enum Style: Sendable, Equatable {
        case color(String), background(String), bold
    }

    /// The `setStyles` arguments, {start. stop. style} triples, as ranges of
    /// `text`; triples that do not fit are left out.
    public static func styles(_ text: String, _ args: [(Int64?, Int64?, String?)]) -> [(NSRange, Style)] {
        var out: [(NSRange, Style)] = []
        for (a, b, s) in args {
            guard let a, let b, let s, let r = nsRange(text, start: Int(a), stop: Int(b)) else { continue }
            if s == "bold" {
                out.append((r, .bold))
            } else if s.hasPrefix("color:") {
                out.append((r, .color(String(s.dropFirst(6)))))
            } else if s.hasPrefix("background:") {
                out.append((r, .background(String(s.dropFirst(11)))))
            }
        }
        return out
    }

    /// A key press as the image names it: modifiers in the order cmd, ctrl,
    /// alt, shift, then the key in lower case (`cmd-s`, `cmd-shift-t`).
    public static func keyName(_ characters: String, command: Bool, control: Bool, option: Bool, shift: Bool) -> String? {
        guard let c = characters.lowercased().first, characters.count == 1 else { return nil }
        var parts: [String] = []
        if command { parts.append("cmd") }
        if control { parts.append("ctrl") }
        if option { parts.append("alt") }
        if shift { parts.append("shift") }
        parts.append(String(c))
        return parts.joined(separator: "-")
    }
}

/// The review fixes (item 12, tools.F1): a view's geometry read back for
/// the image. A whole number is a SmallInteger only while every integer up
/// to it is exact in a Double (|d| < 2^53); anything else (a fraction, a
/// huge or non-finite value a program set) is a Double. `Int64(d)` of an
/// integral Double past Int64's range, or of infinity, trapped the host.
public func geometryValue(_ d: Double) -> ShellValue {
    d.isFinite && d.magnitude < 9_007_199_254_740_992 && d == d.rounded() ? .int(Int64(d)) : .double(d)
}

/// A geometry argument a program gives (x, y, width, height, a frame, an
/// origin, a scroll or divider position): a finite number, else nil and the
/// call is refused (a clean Smalltalk error). AppKit raises an exception
/// for a non-finite frame and UIKit's CALayer for an invalid geometry, both
/// fatal on the main thread (the review fixes, item 12).
public func geometryArgument(_ v: ShellValue) -> Double? {
    guard let d = v.double, d.isFinite else { return nil }
    return d
}
