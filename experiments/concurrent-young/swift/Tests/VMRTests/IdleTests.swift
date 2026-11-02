// Idle cost of the marker threads (SPEC.md amendment 18). A parked VM must
// not wake its marker: the marker waits untimed unless evacuated blocks wait
// for epochs. The second test guards the other side of that rule: every
// transition the marker waits for must signal it, or marking stalls after an
// idle period instead of costing a millisecond.

import Darwin
import Kasm
import Testing
@testable import VMR

private let src = """
class Pair Object 2
method Pair x:y: temps=0
  push_temp 0
  store_ivar 0
  push_temp 1
  store_ivar 1
  return_self
end
; global 7 := an Array of n fresh Pairs, global 8 := every 20th of them.
; t0 = n, t1 = i, t2 = all, t3 = keep, t4 = p
method UndefinedObject mkSparse: temps=4
  push_lit @Array
  push_temp 0
  push_int 20
  send // 1
  send new: 1
  store_temp 3
  push_lit @Array
  push_temp 0
  send new: 1
  store_temp 2
  push_int 1
  store_temp 1
loop:
  push_temp 1
  push_temp 0
  le
  jump_if_false done
  push_lit @Pair
  send basicNew 0
  push_temp 1
  push_nil
  send x:y: 2
  store_temp 4
  push_temp 2
  push_temp 1
  push_temp 4
  send at:put: 2
  pop
  push_temp 1
  push_int 20
  send \\\\ 1
  push_int 0
  eq
  jump_if_false next
  push_temp 3
  push_temp 1
  push_int 20
  send // 1
  push_temp 4
  send at:put: 2
  pop
next:
  push_temp 1
  push_int 1
  add
  store_temp 1
  jump loop
done:
  push_nil
  push_int 7
  push_temp 2
  send globalAt:put: 2
  pop
  push_nil
  push_int 8
  push_temp 3
  send globalAt:put: 2
  return_top
end
"""

/// A threaded runtime with marker threads and background workers, as an app
/// would have it.
private func idleRuntime(_ mode: Int, reloc: Bool) throws -> Runtime {
    let img = try Image.fromSources(try baseSources() + [src], heapSize: 64 << 20, nurseryBytes: 1 << 20)
    var cfg = CMConfig()
    cfg.verify = true
    if reloc { cfg.relocThreshold = 101 } // every live block is relocated
    var y = YCConfig()
    y.mode = mode
    y.verifyYoung = true
    return Runtime(img, background: 3, pollEvery: 64, start: true, verify: true, config: cfg, young: y)
}

private func sleepMs(_ ms: Int) { usleep(useconds_t(ms * 1000)) }

@Test(arguments: [YoungMode.offload, YoungMode.local])
func aParkedVMDoesNotWakeItsMarker(_ mode: Int) throws {
    let rt = try idleRuntime(mode, reloc: true)
    let vm = rt.vm
    #expect(rt.markerThreadCount == 1)
    sleepMs(100) // threads started and parked
    let cpu0 = rt.markerThreadsCpuNs(), waits0 = vm.metric(.cmMarkerWaits)
    sleepMs(1000)
    let cpu = rt.markerThreadsCpuNs() &- cpu0, waits = vm.metric(.cmMarkerWaits) &- waits0
    #expect(cpu < 1_000_000, "marker CPU \(cpu) ns in 1 s parked")
    #expect(waits <= 5, "marker woke \(waits) times in 1 s parked")
    rt.stop()
}

/// Wait for the cycle started as number `n` to be applied: phase idle again,
/// no abort. Answers the milliseconds it took, nil on a timeout.
private func cycleDone(_ vm: VMRef, _ n: UInt64, within s: Double) -> Double? {
    let t0 = now()
    let ok = eventually(s) {
        vm.metric(.cmCycles) >= n && cmPhaseNow(vm) == CMPhase.idle
    }
    return ok ? Double(now() &- t0) / 1e6 : nil
}

@Test(arguments: [YoungMode.offload, YoungMode.local])
func markingCompletesPromptlyAfterIdling(_ mode: Int) throws {
    let rt = try idleRuntime(mode, reloc: true)
    let vm = rt.vm
    sleepMs(300)
    spawn(vm, vm.pointee.nilObj, rt.symbol("mkSparse:"), mkInt(4000))
    waitAllTerminated(vm)
    hostCollect(vm, full: false)              // promote the Pairs
    vm.pointee.globals[6] = vm.pointee.nilObj // drop all but every 20th
    sleepMs(300)
    let c0 = vm.metric(.cmCycles), a0 = vm.metric(.cmAborts)
    // Two cycles, each started after an idle period: the marker must be
    // woken for marking, for sweeping, and kept retrying the evacuated
    // blocks until they are freed.
    for k in 1...2 {
        cmStart(vm)
        let ms = cycleDone(vm, c0 + UInt64(k), within: 3)
        #expect(ms != nil, "cycle \(k) did not finish within 3 s after idling")
        if ms == nil { break }
        #expect(eventually(3) {
            vm.metric(.relocEvacuated) == vm.metric(.relocFreedEpoch) &+ vm.metric(.relocFreedPause)
        }, "evacuated blocks not freed: \(vm.metric(.relocEvacuated)) evacuated")
        sleepMs(200)
    }
    #expect(vm.metric(.cmAborts) == a0)
    #expect(vm.metric(.relocEvacuated) > 0)
    #expect(vm.metric(.cmMissed) == 0)
    #expect(vm.metric(.verifyFailures) == 0)
    rt.stop()
}
