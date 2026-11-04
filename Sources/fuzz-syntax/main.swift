import Darwin
import Dispatch
import KajoCompiler
import KajoVM

/// libFuzzer target for the Smalltalk syntax (`just fuzz syntax <seconds>`):
/// Tonel files and method sources through the bootstrap compiler and the
/// bytecode verifier. Built with `-sanitize=fuzzer -DKAJO_LIBFUZZER`,
/// libFuzzer supplies main and calls this; built plainly, `main` below
/// replays or mutates a corpus.
///
/// Every input runs on a thread of 512 KB, the smallest stack the bootstrap
/// compiler runs on (a Swift Testing or VM worker thread;
/// docs/modules/reserve-and-depth.md): the main thread's 8 MB never showed
/// that a debug build's recursion overflowed it. `KAJO_FUZZ_STACK_KB` sets
/// another size; 0 runs on the calling thread.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let bytes = unsafe Array(UnsafeBufferPointer(start: data, count: size))
    onFuzzStack(bytes)
    return 0
}

let fuzzStackBytes: Int = {
    guard let v = unsafe getenv("KAJO_FUZZ_STACK_KB"), let kb = Int(unsafe String(cString: v)) else { return 512 << 10 }
    return kb << 10
}()

/// One thread of `fuzzStackBytes` for the whole run, handed one input at
/// a time (a thread per input ran a third as many inputs).
final class FuzzStack: @unchecked Sendable {
    var input: [UInt8] = []
    var compiled = false
    let go = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)

    init(stackBytes: Int) {
        var attr = pthread_attr_t()
        unsafe pthread_attr_init(&attr)
        unsafe pthread_attr_setstacksize(&attr, stackBytes)
        var thread: pthread_t? = nil
        let arg = unsafe Unmanaged.passRetained(self).toOpaque()
        let rc = unsafe pthread_create(&thread, &attr, { p in
            let s = unsafe Unmanaged<FuzzStack>.fromOpaque(p).takeRetainedValue()
            while true {
                s.go.wait()
                s.compiled = FuzzSyntax.run(s.input)
                s.done.signal()
            }
        }, arg)
        unsafe pthread_attr_destroy(&attr)
        precondition(rc == 0, "fuzz-syntax: pthread_create failed (\(rc))")
    }

    func run(_ bytes: [UInt8]) -> Bool {
        input = bytes
        go.signal()
        done.wait()
        return compiled
    }
}

let fuzzStack: FuzzStack? = fuzzStackBytes == 0 ? nil : FuzzStack(stackBytes: fuzzStackBytes)

/// `FuzzSyntax.run` on the thread of `fuzzStackBytes`. Answers whether the
/// input compiled.
@discardableResult
func onFuzzStack(_ bytes: [UInt8]) -> Bool {
    guard let s = fuzzStack else { return FuzzSyntax.run(bytes) }
    return s.run(bytes)
}

#if !KAJO_LIBFUZZER
@main
struct Replay {
    static func main() {
        exit(FuzzDriver.main(Array(CommandLine.arguments.dropFirst()), entry: onFuzzStack))
    }
}
#endif
