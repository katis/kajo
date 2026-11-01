// cm-bench kernel <name> <workers>   one key=value line
// Nursery size: KAJO_NURSERY_KB (0 = non-generational, default 4096).
import Darwin
import Kasm
import VMC

let args = CommandLine.arguments
func usage() -> Never {
    fputs("usage: cm-bench kernel <\(kernelNames.joined(separator: "|"))|survivorsP> <workers>\n", stderr)
    exit(1)
}
if args.count < 2 { usage() }
switch args[1] {
case "kernel":
    guard args.count == 4, let n = Int(args[3]) else { usage() }
    do { print(try benchLine(kernel: args[2], workers: n)) } catch { fputs("error: \(error)\n", stderr); exit(1) }
default: usage()
}
