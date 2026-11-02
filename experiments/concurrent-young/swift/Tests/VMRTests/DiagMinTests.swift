// Scratch for DIAGNOSIS-parallel-scavenge.md step 2: the shared-young test
// with knobs from the environment (DIAG_*). Removed after the diagnosis.

import Darwin
import Kasm
import Synchronization
import Testing
@testable import VMR

private func knob(_ n: String, _ d: Int) -> Int {
    getenv(n).flatMap { Int(String(cString: $0)) } ?? d
}

@Test func diagSharedYoungKnobs() throws {
    let procs = knob("DIAG_PROCS", 8), workers = knob("DIAG_WORKERS", 8)
    let iters = knob("DIAG_ITERS", 3000), arr = knob("DIAG_ARR", 32)
    let link = knob("DIAG_LINK", 1), sem = knob("DIAG_SEM", 1), pub = knob("DIAG_PUB", 1)
    let reset = knob("DIAG_RESET", 50), nurseryKB = knob("DIAG_NURSERY_KB", 256)
    let fill = knob("DIAG_FILL", 1)
    let semWait = sem == 1 ? "  push_nil\n  push_int 11\n  send g: 1\n  send wait 0\n  pop\n" : ""
    let semSignal = sem == 1 ? "  push_nil\n  push_int 11\n  send g: 1\n  send signal 0\n  pop\n" : ""
    let publish = pub == 1 ? """
      push_nil
      push_int 9
      send g: 1
      push_temp 0
      push_int 1
      add
      push_temp 3
      send at:put: 2
      pop

    """ : ""
    // x of the list node: the neighbour's published Array (link), else our own.
    let nodeX = link == 1 ? """
      push_nil
      push_int 9
      send g: 1
      push_temp 0
      push_int 1
      add
      push_int \(procs)
      send \\\\ 1
      push_int 1
      add
      send at: 1

    """ : "  push_temp 3\n"
    let fillLoop = fill == 1 ? """
    fill:
      push_temp 4
      push_int \(arr)
      le
      jump_if_false filled
      push_temp 3
      push_temp 4
      push_nil
      push_temp 4
      send pair: 1
      send at:put: 2
      pop
      push_temp 4
      push_int 1
      add
      store_temp 4
      jump fill
    filled:

    """ : ""
    let src = """
    class Pair Object 2
    method Pair x temps=0
      push_ivar 0
      return_top
    end
    method Pair y temps=0
      push_ivar 1
      return_top
    end
    method Pair x:y: temps=0
      push_temp 0
      store_ivar 0
      push_temp 1
      store_ivar 1
      return_self
    end
    method UndefinedObject pair: temps=0
      push_lit @Pair
      send basicNew 0
      push_temp 0
      push_nil
      send x:y: 2
      return_top
    end
    method UndefinedObject g: temps=0
      push_nil
      push_temp 0
      send globalAt: 1
      return_top
    end
    method UndefinedObject g:put: temps=0
      push_nil
      push_temp 0
      push_temp 1
      send globalAt:put: 2
      return_top
    end
    method UndefinedObject makeShared temps=0
      push_nil
      push_int 9
      push_lit @Array
      push_int \(procs)
      send new: 1
      send g:put: 2
      return_top
    end
    method UndefinedObject sharer: temps=5
      push_int 0
      store_temp 1
      push_nil
      store_temp 2
    loop:
      push_temp 1
      push_lit \(iters)
      lt
      jump_if_false done
      push_lit @Array
      push_int \(arr)
      send new: 1
      store_temp 3
      push_int 1
      store_temp 4
    \(fillLoop)\(semWait)\(publish)  push_lit @Pair
      send basicNew 0
    \(nodeX)  push_temp 2
      send x:y: 2
      store_temp 2
    \(semSignal)  push_temp 1
      push_int \(reset)
      send \\\\ 1
      push_int 0
      eq
      jump_if_false keep
      push_nil
      store_temp 2
    keep:
      push_temp 1
      push_int 1
      add
      store_temp 1
      jump loop
    done:
      push_int 1
      return_top
    end
    """
    let rt = try runtime(src, background: workers, nursery: nurseryKB << 10)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    vm.pointee.globals[10] = hostNewSemaphore(vm)
    hostSignal(vm, vm.pointee.globals[10])
    spawn(vm, nilObj, rt.symbol("makeShared"), nilObj)
    waitAllTerminated(vm)
    var ps: [Oop] = []
    for i in 0..<procs { ps.append(spawn(vm, nilObj, rt.symbol("sharer:"), mkInt(Int64(i)))) }
    waitAllTerminated(vm)
    rt.stop()
    for p in ps { #expect(result(rt, p) == 1) }
    FileHandleStderr.write("diag: cycles=\(vm.metric(.cmCycles)) yc=\(vm.metric(.ycCollections)) verifyFailures=\(vm.metric(.verifyFailures)) kept=\(diagCounts[4].load(ordering: .relaxed)) deferPush=\(diagCounts[3].load(ordering: .relaxed)) reallocSnap=\(diagCounts[6].load(ordering: .relaxed)) ycFreeSnap=\(diagCounts[7].load(ordering: .relaxed))\n")
    #expect(vm.metric(.verifyFailures) == 0)
}
