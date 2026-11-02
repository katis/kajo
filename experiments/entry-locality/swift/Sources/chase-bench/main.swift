// chase-bench <chase|dsep|dlocal|dhalf|spread> <sizeMB> <threads> [work]
// One configuration per process (SPEC.md "Part 1").
import Darwin
import MemChase

let a = CommandLine.arguments
guard a.count >= 4, let mb = Int(a[2]), let t = Int(a[3]) else {
    print("usage: chase-bench <chase|dsep|dlocal|dhalf|spread> <sizeMB> <threads> [work]")
    exit(1)
}
let streamMB = getenv("KAJO_STREAM_MB").flatMap { Int(String(cString: $0)) } ?? 0
let streamer = streamMB > 0 ? Streamer(mb: streamMB) : nil
let u0 = ProcUsage.now()
var line = runChase(ChaseSpec(mode: a[1], sizeMB: mb, threads: t, work: a.count > 4 ? Int(a[4]) ?? 0 : 0))
let u1 = ProcUsage.now()
if let st = streamer { line += " stream_mb=\(streamMB) stream_mbs=\(Int(st.finish()))" }
print(line + ProcUsage.line(u0, u1))
