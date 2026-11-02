// Helpers for the nursery tests (docs/modules/nursery.md). Every runtime has
// every verifier on (`Runtime` sets `verify` and `.record`): each scavenge
// checks the remembered-set invariant before copying, and after it that
// each reachable young object was copied exactly once, that young bodies lie
// in their nursery's eden or survivor-from, that nothing names a freed
// entry and that weak slots were nil'ed exactly when their referent died.

import Darwin
import Testing
@testable import KajoVM

/// Pair (2 ivars) and helpers. Ported from experiments/generational-gc's
/// GenerationalTests.swift.
let pairSrc = """
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
; nil pair: x  ->  a fresh Pair x: x y: nil
method UndefinedObject pair: temps=0
  push_lit @Pair
  send basicNew 0
  push_temp 0
  push_nil
  send x:y: 2
  return_top
end
; nil g: i  /  nil g: i put: v
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
; nil waitOn: i  -- wait on the Semaphore in global i
method UndefinedObject waitOn: temps=0
  push_nil
  push_temp 0
  send g: 1
  send wait 0
  return_top
end
; nil list: n  ->  a list of n Pairs, x = 1..n, linked through y (head = n)
; t0 = n, t1 = i, t2 = head
method UndefinedObject list: temps=2
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
  push_temp 2
  return_top
end
; nil sumList: l  ->  sum of x over the list. t0 = l, t1 = sum
method UndefinedObject sumList: temps=1
  push_int 0
  store_temp 1
loop:
  push_temp 0
  push_nil
  identical
  jump_if_true done
  push_temp 1
  push_temp 0
  send x 0
  add
  store_temp 1
  push_temp 0
  send y 0
  store_temp 0
  jump loop
done:
  push_temp 1
  return_top
end
; nil churn: n  allocate n Pairs and drop them. t0 = n, t1 = i
method UndefinedObject churn: temps=1
  push_int 0
  store_temp 1
loop:
  push_temp 1
  push_temp 0
  lt
  jump_if_false done
  push_nil
  push_temp 1
  send pair: 1
  pop
  push_temp 1
  push_int 1
  add
  store_temp 1
  jump loop
done:
  push_temp 1
  return_top
end

"""

/// A runtime whose workers the test drives (`start: false`), with a
/// nursery of `nurseryKB` per worker and promotion after `age` survivals.
func nurseryRuntime(_ src: String, background: Int = 1, age: Int = 2, nurseryKB: Int = 1024, survivorKB: Int = 0,
                    start: Bool = false, heapBlocks: Int = 2048,
                    configure: (inout VMConfig) -> Void = { _ in }) throws -> Runtime {
    try Runtime(src, background: background, heapBlocks: heapBlocks, start: start, configure: { c in
        c.nursery.bytes = nurseryKB * 1024
        c.nursery.survivorBytes = survivorKB * 1024
        c.nursery.age = age
        configure(&c)
    })
}

extension Runtime {
    /// Run one ready "any" Process on background worker `i` from this
    /// thread, so the test decides which nursery it allocates in.
    func runOn(_ i: Int) { #expect(vm.runOneSlice(worker: i)) }

    func slot(_ o: Oop, _ i: Int) -> Oop { vm.inspect { $0.load(o, i) } }
    func header(_ o: Oop) -> Header { vm.inspect { $0.header(o) } }
    func young(_ o: Oop) -> Bool { header(o).isYoung }
    func age(_ o: Oop) -> Int { Int(header(o).age) }
    func remembered(_ o: Oop) -> Bool { vm.isRemembered(o) }
    func space(_ o: Oop) -> NurserySpace { vm.space(of: o) }
    func scavenge() { vm.scavenge() }

    /// No verifier failed (module 1's, the nursery's, the stop verifiers).
    func noFailures(_ s: Testing.SourceLocation = #_sourceLocation) {
        let c = image.om.counters
        #expect(c.verifierFailures == 0, "\(image.om.verifierReports.prefix(3))", sourceLocation: s)
    }

    /// The test's own Semaphore, rooted, in global `i`.
    @discardableResult
    func semaphore(global i: Int) -> Oop {
        let s = vm.newSemaphore()
        vm.setGlobal(i, s)
        return s
    }
}

/// The verifier runs and failures counted by the object memory.
func verifierCounts(_ rt: Runtime) -> (runs: UInt64, failures: UInt64) {
    let c = rt.image.om.counters
    return (c.verifierRuns, c.verifierFailures)
}
