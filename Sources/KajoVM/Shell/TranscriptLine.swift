import Foundation

/// The third review's small fixes, item 5 (hosts.M1): the text of a line the
/// image wrote when it is a Transcript event, nil for any other line. Every
/// host's sink called it on every line, replies of the development protocol
/// included, and parsed each one whole to learn its kind. The event writer
/// (primitive 140, `KernelPrimitives.swift`) starts every event with
/// `{"v":1,"kind":` and the kind's JSON string, so one prefix compare
/// decides, and only a Transcript line is parsed. A reply starts with its
/// own fields and never matches, whatever its strings hold.
public func transcriptText(ofLine line: [UInt8]) -> String? {
    guard line.count > transcriptPrefix.count, line.starts(with: transcriptPrefix) else { return nil }
    guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
          o["kind"] as? String == "transcript" else { return nil }
    return o["text"] as? String
}

private let transcriptPrefix = Array(#"{"v":1,"kind":"transcript","#.utf8)
