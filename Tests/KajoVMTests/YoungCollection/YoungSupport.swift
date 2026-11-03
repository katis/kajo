// Helpers for the young-collection tests (docs/modules/young-collection.md).
// Runtimes are driven from the test thread (`start: false`): the test acts
// as the collecting worker (`VM.collectYoung(worker:)`), runs other
// workers' slices from collector hooks or helper threads, and the young
// verifier runs at a stop after every collection.

import Darwin
import Foundation
import Synchronization
import Testing
@testable import KajoVM

/// Pair plus: `x:`, `slowPeek:` (primitive 39), and the experiment's
/// methods (experiments/concurrent-young YoungTests.swift). Globals: 8 Y or
/// P, 9 H or O, 10 a Semaphore or X, 11 and 12 stop flags, 13 G.
let youngSrc = pairSrc + """
method Pair x: temps=0
  push_temp 0
  store_ivar 0
  return_self
end
method Object slowPeek: temps=0 prim=39
  push_nil
  return_top
end
method Object replaceFrom:to:with:startingAt: temps=0 prim=38
  push_lit @Object
  return_top
end
; global 8 := P (Pair x: (Pair x: 42)): P in this worker's nursery holding Y.
method UndefinedObject mkP temps=0
  push_nil
  push_int 8
  push_nil
  push_nil
  push_int 42
  send pair: 1
  send pair: 1
  send g:put: 2
  pop
  push_nil
  return_top
end
; global 8 := Y (Pair x: 42). Answers nil (a result slot would hold Y).
method UndefinedObject mkY temps=0
  push_nil
  push_int 8
  push_nil
  push_int 42
  send pair: 1
  send g:put: 2
  pop
  push_nil
  return_top
end
; Take Y out of P (global 8), clear P's slot, wait on global 10 holding
; Y; answer Y x.
method UndefinedObject steal temps=1
  push_nil
  push_int 8
  send g: 1
  send x 0
  store_temp 0
  push_nil
  push_int 8
  send g: 1
  push_nil
  send x: 1
  pop
  push_nil
  push_int 10
  send g: 1
  send wait 0
  pop
  push_temp 0
  send x 0
  return_top
end
; global 9 := H (a Pair in this worker's nursery) x: Y (global 8);
; global 8 := nil.
method UndefinedObject hold temps=0
  push_nil
  push_int 9
  push_nil
  push_nil
  push_int 8
  send g: 1
  send pair: 1
  send g:put: 2
  pop
  push_nil
  push_int 8
  push_nil
  send g:put: 2
  pop
  push_nil
  return_top
end
; H x x
method UndefinedObject readH temps=0
  push_nil
  push_int 9
  send g: 1
  send x 0
  send x 0
  return_top
end
; Take Y (global 8), clear global 8, spin until global 11 is not nil
; (polling), answer Y x.
method UndefinedObject spinHolding temps=1
  push_nil
  push_int 8
  send g: 1
  store_temp 0
  push_nil
  push_int 8
  push_nil
  send g:put: 2
  pop
loop:
  push_nil
  push_int 11
  send g: 1
  push_nil
  identical
  jump_if_true loop
  push_temp 0
  send x 0
  return_top
end
; (global 8) slowPeek: 1
method UndefinedObject peek temps=0
  push_nil
  push_int 8
  send g: 1
  push_int 1
  send slowPeek: 1
  return_top
end
; Old O (global 9) x: Y (global 8).
method UndefinedObject linkOY temps=0
  push_nil
  push_int 9
  send g: 1
  push_nil
  push_int 8
  send g: 1
  send x: 1
  pop
  push_nil
  return_top
end
; global 9 := Pair (to be made old).
method UndefinedObject mkO temps=0
  push_nil
  push_int 9
  push_nil
  push_int 7
  send pair: 1
  send g:put: 2
  pop
  push_nil
  return_top
end
; global 12 := a list of n Pairs (x = 1..n, linked through y). t0 = n,
; t1 = i, t2 = head
method UndefinedObject keep: temps=2
  push_int 1
  store_temp 1
  push_nil
  store_temp 2
loop:
  push_temp 1
  push_temp 0
  le
  jump_if_false done
  push_lit @Pair
  send basicNew 0
  push_temp 1
  push_temp 2
  send x:y: 2
  store_temp 2
  push_temp 1
  push_int 1
  add
  store_temp 1
  jump loop
done:
  push_nil
  push_int 12
  push_temp 2
  send g:put: 2
  pop
  push_nil
  return_top
end
method UndefinedObject sumKeep temps=0
  push_nil
  push_nil
  push_int 12
  send g: 1
  send sumList: 1
  return_top
end
; global 13 := G, an Array of 2 (made old by the test).
method UndefinedObject mkG temps=0
  push_nil
  push_int 13
  push_lit @Array
  push_int 2
  send new: 1
  send g:put: 2
  pop
  push_nil
  return_top
end
; G at: 1 put: a fresh Pair (G is remembered for this nursery), then
; G at: 1 put: nil: G keeps its remembered bit and names nothing young.
method UndefinedObject armG temps=0
  push_nil
  push_int 13
  send g: 1
  push_int 1
  push_nil
  push_int 5
  send pair: 1
  send at:put: 2
  pop
  push_nil
  push_int 13
  send g: 1
  push_int 1
  push_nil
  send at:put: 2
  pop
  push_nil
  return_top
end
; global 10 := X (Pair x: 42).
method UndefinedObject mkX temps=0
  push_nil
  push_int 10
  push_nil
  push_int 42
  send pair: 1
  send g:put: 2
  pop
  push_nil
  return_top
end
; Take X (global 10) and clear it; spin until global 11 (the collector's
; H1 is done); copy X into G at: 2 through a fresh Array and primitive 38;
; drop X; spin until global 12. t0 = x, t1 = s
method UndefinedObject copier temps=2
  push_nil
  push_int 10
  send g: 1
  store_temp 0
  push_nil
  push_int 10
  push_nil
  send g:put: 2
  pop
wait1:
  push_nil
  push_int 11
  send g: 1
  push_nil
  identical
  jump_if_true wait1
  push_lit @Array
  push_int 1
  send new: 1
  store_temp 1
  push_temp 1
  push_int 1
  push_temp 0
  send at:put: 2
  pop
  push_nil
  push_int 13
  send g: 1
  push_int 2
  push_int 2
  push_temp 1
  push_int 1
  send replaceFrom:to:with:startingAt: 4
  pop
  push_nil
  store_temp 0
  push_nil
  store_temp 1
wait2:
  push_nil
  push_int 12
  send g: 1
  push_nil
  identical
  jump_if_true wait2
  push_int 0
  return_top
end
; G at: 2, then its x
method UndefinedObject readG temps=0
  push_nil
  push_int 13
  send g: 1
  push_int 2
  send at: 1
  send x 0
  return_top
end

"""

/// A young-collection runtime the test drives: `background` workers
/// (nursery 1 MiB, promotion at the second survival), no marking unless
/// asked, the young verifier after every collection.
func youngRuntime(_ mode: YoungMode, src: String = youngSrc, background: Int = 3, age: Int = 2, marking: Bool = false,
                  start: Bool = false, _ change: (inout VMConfig) -> Void = { _ in }) throws -> Runtime {
    try Runtime(src, background: background, start: start, configure: { c in
        c.nursery.bytes = 1 << 20
        c.nursery.age = age
        c.young.mode = mode
        c.young.verify = true
        c.young.verifyEvery = 1
        c.marking.enabled = marking
        c.marking.markerThread = false
        c.marking.floor = 2  // no cycle unless the test starts one
        c.marking.safetyFactor = 0
        change(&c)
    })
}

/// Collector hooks (`YoungTestSwitches.hook`): an action per point, run on
/// the collector's thread. Under a lock: the collector thread reads them
/// while the test thread sets them.
final class YoungHooks: @unchecked Sendable {
    private let lock = NSLockish()
    private var actions: [Int: (Int) -> Void] = [:]
    var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    func set(_ point: Int, _ action: ((Int) -> Void)?) {
        lock.locked { actions[point] = action }
    }

    func run(_ k: Int, _ point: Int) {
        let a = lock.locked { actions[point] }
        a?(k)
    }

    func install(_ s: inout YoungTestSwitches) {
        s.hook = youngHookThunk
        s.hookContext = context
    }
}

let youngHookThunk: YoungHook = { ctx, k, point in
    guard let ctx else { return }
    Unmanaged<YoungHooks>.fromOpaque(ctx).takeUnretainedValue().run(k, point)
}

/// A tiny pthread mutex wrapper for test helpers.
final class NSLockish: @unchecked Sendable {
    private let m: UnsafeMutablePointer<pthread_mutex_t>
    init() {
        m = .allocate(capacity: 1)
        pthread_mutex_init(m, nil)
    }
    deinit {
        pthread_mutex_destroy(m)
        m.deallocate()
    }
    func locked<T>(_ body: () -> T) -> T {
        pthread_mutex_lock(m)
        defer { pthread_mutex_unlock(m) }
        return body()
    }
}

extension Runtime {
    var verifierFailures: UInt64 {
        let n = image.om.counters.verifierFailures
        if n > 0, ProcessInfo.processInfo.environment["KAJO_SHOW_REPORTS"] != nil {
            print("REPORT: \(image.om.verifierReports.first ?? "-")")
        }
        return n
    }

    /// Run every ready "any" Process on worker `i` to completion.
    func drain(on i: Int) { while vm.runOneSlice(worker: i) {} }
}
