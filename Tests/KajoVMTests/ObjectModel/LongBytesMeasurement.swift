// Large bytes, part 1: the measurements (KAJO_MEASURE_LONGBYTES=1,
// release with -enable-testing): for ByteArrays of 16, 64, 256 MiB and 1
// GiB, a VM with one background worker allocates one (`new:`, zeroed in
// polled chunks), writes and reads every byte (`at:put:`, `at:` loops),
// copies it into another (`replaceFrom:to:with:startingAt:`, primitive
// 38), and frees both (a full collection after dropping them, against one
// without). While the copy runs the host stops the world every 2 ms: the
// time each stop took to begin is the stretch the primitive kept it
// waiting. The longest stretch of byte work between two polls is the
// workers' counter (bytes). Then the copy at 256 MiB with polls off (the
// broken variant) for the stop latency it costs.

import Foundation
import Testing
@testable import KajoVM

private let longSource = """
method UndefinedObject mk:at: temps=0
  push_nil
  push_temp 1
  push_lit @ByteArray
  push_temp 0
  send new: 1
  send g:put: 2
  pop
  push_int 0
  return_top
end
method UndefinedObject fill:at: temps=2
  push_nil
  push_temp 1
  send g: 1
  store_temp 2
  push_int 1
  store_temp 3
loop:
  push_temp 3
  push_temp 0
  le
  jump_if_false done
  push_temp 2
  push_temp 3
  push_int 1
  send at:put: 2
  pop
  push_temp 3
  push_int 1
  add
  store_temp 3
  jump loop
done:
  push_int 0
  return_top
end
method UndefinedObject sum:at: temps=3
  push_nil
  push_temp 1
  send g: 1
  store_temp 2
  push_int 0
  store_temp 4
  push_int 1
  store_temp 3
loop:
  push_temp 3
  push_temp 0
  le
  jump_if_false done
  push_temp 4
  push_temp 2
  push_temp 3
  send at: 1
  add
  store_temp 4
  push_temp 3
  push_int 1
  add
  store_temp 3
  jump loop
done:
  push_temp 4
  return_top
end
method Object lbReplace:a:a:a: temps=0 prim=38
  push_nil
  return_top
end
method UndefinedObject copy:from:to: temps=0
  push_nil
  push_temp 2
  send g: 1
  push_int 1
  push_temp 0
  push_nil
  push_temp 1
  send g: 1
  push_int 1
  send lbReplace:a:a:a: 4
  pop
  push_int 0
  return_top
end
"""

private func ms(_ ns: UInt64) -> String { String(format: "%.3f", Double(ns) / 1e6) }

@Test func longByteObjectsMeasured() throws {
    guard ProcessInfo.processInfo.environment["KAJO_MEASURE_LONGBYTES"] != nil else { return }
    for (mib, polls) in [(16, true), (64, true), (256, true), (1024, true), (256, false)] {
        let n = mib << 20
        let rt = try Runtime(pairSrc + longSource, background: 1, heapBlocks: 72 * 1024, entries: 1 << 20, start: true,
                             verify: false, configure: { c in c.testSwitches.noBytePolls = !polls })
        func timed(_ sel: String, _ args: [Oop]) -> (UInt64, Oop) {
            let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let p = rt.spawn(sel, args)
            _ = rt.waitAllTerminated(600)
            let dt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0
            let v = rt.vm.result(of: p)
            rt.vm.release(p)
            return (dt, v)
        }
        let (alloc, _) = timed("mk:at:", [int(Int64(n)), int(8)])
        let (alloc2, _) = timed("mk:at:", [int(Int64(n)), int(9)])
        var fill: UInt64 = 0, sum: UInt64 = 0
        if polls && mib <= 1024 {
            (fill, _) = timed("fill:at:", [int(Int64(n)), int(8)])
            let (s, v) = timed("sum:at:", [int(Int64(n)), int(8)])
            sum = s
            #expect(v == int(Int64(n)), "sum \(v)")
        }
        // The copy, with the host stopping the world every 2 ms meanwhile.
        let p = rt.spawn("copy:from:to:", [int(Int64(n)), int(8), int(9)])
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var waits: [UInt64] = []
        while rt.vm.liveProcessCount > 0 {
            let s0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            rt.vm.withWorldStopped {}
            waits.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - s0)
            usleep(2000)
        }
        let copy = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0
        rt.vm.release(p)
        let bw = rt.vm.byteWorkCounters
        // Free: a full collection with both dropped, against one with them.
        let c0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        rt.vm.collect()
        let keepNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - c0
        rt.vm.setGlobal(8, rt.image.nilObject)
        rt.vm.setGlobal(9, rt.image.nilObject)
        let c1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        rt.vm.collect()
        let freeNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - c1
        let w = waits.sorted()
        print("long bytes \(mib) MiB polls=\(polls): allocate \(ms(alloc)) ms (second \(ms(alloc2))), at:put: over all \(ms(fill)) ms (\(String(format: "%.2f", Double(fill) / Double(n))) ns/byte), at: over all \(ms(sum)) ms, "
              + "copy \(ms(copy)) ms, stops during the copy \(w.count) p50 \(ms(w.isEmpty ? 0 : w[w.count / 2])) max \(ms(w.last ?? 0)) ms, "
              + "longest stretch \(bw.longestStretch) B, polls \(bw.polls), parks \(bw.parks), collection keeping both \(ms(keepNs)) ms, freeing both \(ms(freeNs)) ms")
        rt.stop(verifyHeap: false)
    }
}
