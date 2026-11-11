import Darwin
import KajoAOT
import KajoVM

/// AOT 1 (open question 2): KAJO_FUZZ_AOT=1 runs the generator over every
/// image an input loads: it emits or declines, never traps.
let fuzzAOT = unsafe getenv("KAJO_FUZZ_AOT") != nil

func generateAll(_ image: Image) {
    let o = AOTGenerator.generate(image.nativeMethodInfos(), nilOop: image.nilOop, trueOop: image.trueOop, falseOop: image.falseOop)
    precondition(o.methods + o.declined.count > 0 || image.nativeMethodInfos().isEmpty)
}

/// libFuzzer target for the kasm loader (`just fuzz kasm <seconds>`). Built
/// with `-sanitize=fuzzer -DKAJO_LIBFUZZER`, libFuzzer supplies main and
/// calls this; built plainly, `main` below replays or mutates a corpus.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let bytes = unsafe Array(UnsafeBufferPointer(start: data, count: size))
    if fuzzAOT { _ = FuzzEntry.kasm(bytes, then: generateAll) } else { _ = FuzzEntry.kasm(bytes) }
    return 0
}

#if !KAJO_LIBFUZZER
@main
struct Replay {
    static func main() {
        exit(FuzzDriver.main(Array(CommandLine.arguments.dropFirst()), entry: { fuzzAOT ? FuzzEntry.kasm($0, then: generateAll) : FuzzEntry.kasm($0) }))
    }
}
#endif
