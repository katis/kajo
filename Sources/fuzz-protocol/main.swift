import Darwin
import KajoDev
import KajoVM

/// libFuzzer target for the development protocol's request parser (module
/// 9b, `just fuzz protocol <seconds>`): whatever a connection sends, line by
/// line, is a request or a refusal, never a trap, and what the transport
/// hands the kernel (a request's canonical form) reads back as the same
/// request. Built with `-sanitize=fuzzer -DKAJO_LIBFUZZER`, libFuzzer
/// supplies main and calls this; built plainly, `main` below replays or
/// mutates a corpus.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let bytes = unsafe Array(UnsafeBufferPointer(start: data, count: size))
    _ = fuzzProtocol(bytes)
    return 0
}

/// One input: every line through the request parser; each accepted
/// request's canonical text parsed again (the same request), its line form
/// too; the whole input through the JSON reader, and an accepted value
/// written and read again (the same value); the project writer's file-name
/// rule on each line; each line as the client's transport receives it
/// (module 9c). Answers whether any line was a request.
func fuzzProtocol(_ bytes: [UInt8]) -> Bool {
    var any = false
    for line in bytes.split(separator: 10, maxSplits: 64, omittingEmptySubsequences: false) {
        let l = Array(line)
        switch parseRequest(l) {
        case .success(let r):
            any = true
            guard case .success(let again) = parseRequest(r.line), again.kind == r.kind, again.id == r.id,
                  again.arguments.count == r.arguments.count,
                  zip(again.arguments, r.arguments).allSatisfy({ $0.0 == $1.0 && $0.1 == $1.1 }) else {
                fatalError("a request's line form does not read back as itself: \(String(decoding: l, as: UTF8.self))")
            }
            guard case .success(let v) = parseJSON(r.canonical), v["kind"] == .string(r.kind), v["id"] == r.id else {
                fatalError("a request's canonical form does not read back: \(String(decoding: l, as: UTF8.self))")
            }
        case .failure(let refusal):
            _ = errorReply(id: refusal.id, refusal.message)
        }
        if let s = String(validating: l, as: UTF8.self) { _ = ProjectWriter.isSourceFileName(s) }
        // Module 9c: the same line as the client's transport receives it
        // from a target: a value or a client.error object, whose text the
        // image is given in pieces that join back to it.
        let text = String(decoding: writeJSON(ClientHost.check(l)), as: UTF8.self)
        let pieces = linePieces(text, limit: 32)
        guard pieces.joined() == text, pieces.allSatisfy({ $0.utf8.count <= 32 }) else {
            fatalError("a client line's pieces do not join back: \(String(decoding: l, as: UTF8.self))")
        }
        fuzzTransport(l)
    }
    if case .success(let v) = parseJSON(bytes) {
        guard case .success(let w) = parseJSON(writeJSON(v)), w == v else {
            fatalError("a JSON value does not read back as itself: \(String(decoding: bytes, as: UTF8.self))")
        }
    }
    return any
}

/// Module 9d: what the network and the targets file hand the transport.
/// A line as an address (an accepted one reads back as itself and never
/// holds a tab or a line break), as a targets-file line (its name and
/// address accepted the same way), and its bytes as a TXT record (every
/// pair checked, and written and read back the same).
func fuzzTransport(_ l: [UInt8]) {
    let text = String(decoding: l, as: UTF8.self)
    if let a = TargetAddress.parse(text) {
        guard TargetAddress.parse(a.description) == a, !a.description.contains("\t"), !a.description.contains("\n") else {
            fatalError("an address does not read back as itself: \(text)")
        }
    }
    if let t = ClientHost.targetLine(text) {
        guard ClientHost.isTargetName(t.name), TargetAddress.parse(t.path) != nil, !t.name.contains("\t") else {
            fatalError("a targets line was accepted with a bad name or address: \(text)")
        }
    }
    let pairs = TXTRecord.decode(l)
    for (k, v) in pairs {
        guard TXTRecord.checked(Array(k.utf8), Array(v.utf8)) != nil else { fatalError("a TXT pair passed unchecked: \(text)") }
    }
    let again = TXTRecord.decode(TXTRecord.encode(pairs))
    guard again.count == pairs.count, zip(again, pairs).allSatisfy({ $0.0 == $1.0 && $0.1 == $1.1 }) else {
        fatalError("a TXT record does not read back: \(text)")
    }
}

#if !KAJO_LIBFUZZER
@main
struct Replay {
    static func main() {
        exit(FuzzDriver.main(Array(CommandLine.arguments.dropFirst()), entry: fuzzProtocol))
    }
}
#endif
