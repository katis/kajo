import Darwin
import KajoVM

/// libFuzzer target for the snapshot loader (`just fuzz snapshot <seconds>`). Built
/// with `-sanitize=fuzzer -DKAJO_LIBFUZZER`, libFuzzer supplies main and
/// calls this; built plainly, `main` below replays or mutates a corpus.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let bytes = unsafe Array(UnsafeBufferPointer(start: data, count: size))
    _ = FuzzEntry.snapshot(bytes)
    return 0
}

#if !KAJO_LIBFUZZER
@main
struct Replay {
    static func main() {
        exit(FuzzDriver.main(Array(CommandLine.arguments.dropFirst()), entry: FuzzEntry.snapshot, makeSeed: FuzzEntry.snapshotSeed))
    }
}
#endif
