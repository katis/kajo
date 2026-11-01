// uts-bench kernel <name> <workers>   one key=value line
// uts-bench clock                     cost of the budget clock read
import Darwin
import Kasm
import VMP

let args = CommandLine.arguments
func usage() -> Never {
    fputs("usage: uts-bench kernel <arith|fib|sends|alloc> <workers>\n       uts-bench clock\n", stderr)
    exit(1)
}
if args.count < 2 { usage() }
switch args[1] {
case "kernel":
    guard args.count == 4, let n = Int(args[3]) else { usage() }
    do { print(try benchLine(kernel: args[2], workers: n)) } catch { fputs("error: \(error)\n", stderr); exit(1) }
case "clock":
    let iters = 20_000_000
    var acc: UInt64 = 0
    let t0 = now()
    for _ in 0..<iters { acc &+= ticks() }
    let ns = Double(now() - t0) / Double(iters)
    let t1 = now()
    for _ in 0..<iters { acc &+= now() }
    let ns2 = Double(now() - t1) / Double(iters)
    print("clock mach_absolute_time_ns=\(ns) clock_gettime_nsec_np_ns=\(ns2) sink=\(acc & 1)")
default: usage()
}
