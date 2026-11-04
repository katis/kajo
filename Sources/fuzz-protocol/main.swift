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
/// rule on each line. Answers whether any line was a request.
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
    }
    if case .success(let v) = parseJSON(bytes) {
        guard case .success(let w) = parseJSON(writeJSON(v)), w == v else {
            fatalError("a JSON value does not read back as itself: \(String(decoding: bytes, as: UTF8.self))")
        }
    }
    return any
}

#if !KAJO_LIBFUZZER
@main
struct Replay {
    static func main() {
        exit(FuzzDriver.main(Array(CommandLine.arguments.dropFirst()), entry: fuzzProtocol))
    }
}
#endif
