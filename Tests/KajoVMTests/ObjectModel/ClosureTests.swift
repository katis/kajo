// Closures, temp vectors, non-local return, unwinding, Contexts and
// exceptions (ADR 0009 sections 3 to 5) on module 2's standalone
// interpreter, with the test kernel `objectmodel.kasm`.

import Testing
@testable import KajoVM

/// A harness with the prelude and the object-model kernel.
func omHarness(_ src: String, stress: StressFlags = [], stackWords: Int = 1 << 16,
               switches: TestSwitches = TestSwitches()) throws -> Harness {
    try Harness(src, base: ["prelude", "objectmodel"], stress: stress, stackWords: stackWords, switches: switches)
}

@Test func aClosureAddsItsArgumentToACopiedValue() throws {
    let h = try omHarness(runOf("""
      push_int 10
      store_temp 2
      push_temp 2
      push_closure add 1
      push_int 3
      value1
      return_top
    block add args=1 copied=1 temps=0
      push_temp 0
      push_temp 1
      add
      block_return
    """, temps: 1))
    defer { h.destroy() }
    #expect(try h.value() == 13)
    #expect(h.interpreter.counters.closuresCreated == 1 && h.interpreter.counters.closureActivations == 1)
}

@Test func aTempVectorIsSharedBetweenAMethodAndItsClosure() throws {
    // tv := Array new: 1. tv at 0 := 0. 5 times: [tv at 0 := (tv at 0) + 2] value. ^tv at 0
    let h = try omHarness(runOf("""
      push_new_array 1
      store_temp 2
      push_int 0
      store_tv_slot 0 2
      push_int 5
      store_temp 3
    loop:
      push_temp 3
      push_int 0
      gt
      jump_if_false done
      push_temp 2
      push_closure bump 1
      value
      pop
      push_temp 3
      push_int 1
      sub
      store_temp 3
      jump loop
    done:
      push_tv_slot 0 2
      return_top
    block bump args=0 copied=1 temps=0
      push_tv_slot 0 0
      push_int 2
      add
      store_tv_slot 0 0
      push_nil
      block_return
    """, temps: 2))
    defer { h.destroy() }
    #expect(try h.value() == 10)
}

@Test func blocksNestAndValueSendsWorkWithoutTheSpecialBytecodes() throws {
    // [:a | [:b | a * b]] value: 6 -> inner; inner value: 7 (as real sends)
    let h = try omHarness(runOf("""
      push_closure outer 0
      push_int 6
      send value: 1
      push_int 7
      send value: 1
      push_closure two 0
      push_int 1
      push_int 2
      send value:value: 2
      add
      push_closure two2 0
      push_lit @Array
      push_int 2
      send new: 1
      dup
      push_int 1
      push_int 20
      at_put
      pop
      dup
      push_int 2
      push_int 30
      at_put
      pop
      send valueWithArguments: 1
      add
      return_top
    block outer args=1 copied=0 temps=0
      push_temp 0
      push_closure inner 1
      block_return
    block inner args=1 copied=1 temps=0
      push_temp 1
      push_temp 0
      mul
      block_return
    block two args=2 copied=0 temps=0
      push_temp 0
      push_temp 1
      add
      block_return
    block two2 args=2 copied=0 temps=0
      push_temp 0
      push_temp 1
      add
      block_return
    """))
    defer { h.destroy() }
    #expect(try h.value() == 42 + 3 + 50)
}

@Test func aClosureWithTheWrongArgumentCountIsARealSend() throws {
    let h = try omHarness("""
    method BlockClosure value:value:value: temps=0
      push_int 99
      return_top
    end
    """ + runOf("""
      push_closure one 0
      value
      return_top
    block one args=1 copied=0 temps=0
      push_temp 0
      block_return
    """))
    defer { h.destroy() }
    // value on a one-argument block: prim 80 fails, the method has no
    // bytecodes: primitiveFailed.
    let e = try #require(h.error())
    #expect(e.kind == .primitiveFailed && e.primitive == 80)
}

// MARK: - non-local return

private let detectSrc = """
class Finder Object 0
; Finder find: n  -> answers 2n via a non-local return from a block
method Finder find: temps=0
  push_self
  push_temp 0
  push_closure ret 1
  send apply: 1
  pop
  push_int 0
  return_top
block ret args=1 copied=1 temps=0
  push_temp 1
  push_temp 0
  mul
  nonlocal_return
end
method Finder apply: temps=0
  push_temp 0
  push_int 2
  value1
  pop
  push_int -1
  return_top
end
"""

@Test func aNonLocalReturnLeavesFromTheHomeMethod() throws {
    let h = try omHarness(detectSrc + runOf("""
      push_lit @Finder
      send basicNew 0
      push_int 21
      send find: 1
      return_top
    """))
    defer { h.destroy() }
    #expect(try h.value() == 42)
    let c = h.interpreter.counters
    #expect(c.nonLocalReturns == 1 && c.unwindingReturns == 0 && c.contextsMaterialized == 0)
}

/// The rule: a non-local return that crosses an unwind mark unwinds
/// through the kernel (the ensure block runs). Broken variant (test switch
/// `skipUnwindMarks`): the return cuts to its home and the block never runs.
@Test(arguments: [false, true])
func aNonLocalReturnRunsTheEnsureBlocksItCrosses(_ broken: Bool) throws {
    // [[^7] value] ensure: [global 1 := 5]; the method answers 7, the
    // ensure block ran once, the unwinding went through the kernel.
    var sw = TestSwitches()
    sw.skipUnwindMarks = broken
    let h = try omHarness("""
    class U Object 0
    method U run temps=0
      push_closure body 0
      push_closure cleanup 0
      send ensure: 1
      pop
      push_int -1
      return_top
    block body args=0 copied=0 temps=0
      push_closure ret 0
      value
      block_return
    block ret args=0 copied=0 temps=0
      push_int 7
      nonlocal_return
    block cleanup args=0 copied=0 temps=0
      push_nil
      push_int 1
      push_nil
      push_int 1
      send globalAt: 1
      push_int 5
      add
      send globalAt:put: 2
      block_return
    end
    method UndefinedObject globalAt: temps=0 prim=14
    end
    method UndefinedObject globalAt:put: temps=0 prim=15
    end
    """ + runOf("""
      push_nil
      push_int 1
      push_int 0
      send globalAt:put: 2
      pop
      push_lit @U
      send basicNew 0
      send run 0
      push_nil
      push_int 1
      send globalAt: 1
      push_int 100
      mul
      add
      return_top
    """), switches: sw)
    defer { h.destroy() }
    if broken {
        #expect(try h.value() == 7)  // the ensure block did not run
        return
    }
    #expect(try h.value() == 7 + 500)
    let c = h.interpreter.counters
    #expect(c.unwindingReturns == 1 && c.terminations >= 2)
    #expect(h.stack.guardIntact)
}

@Test func aBlockWhoseHomeReturnedIsSentCannotReturn() throws {
    let h = try omHarness("""
    class K Object 0
    method K make temps=0
      push_closure ret 0
      return_top
    block ret args=0 copied=0 temps=0
      push_int 5
      nonlocal_return
    end
    method BlockClosure cannotReturn: temps=0
      push_temp 0
      push_int 90
      add
      return_top
    end
    """ + runOf("""
      push_lit @K
      send basicNew 0
      send make 0
      value
      push_lit 1000
      add
      return_top
    """))
    defer { h.destroy() }
    // cannotReturn: 5 answers 95, which the block returns (cascade).
    #expect(try h.value() == 1095)
    #expect(h.interpreter.counters.cannotReturns == 1)
}

// MARK: - Contexts

@Test func thisContextIsMaterializedOnDemandAndDetachedOnReturn() throws {
    let h = try omHarness("""
    class Probe Object 1
    method Probe grab: temps=1
      push_int 77
      store_temp 1
      push_this_context
      store_ivar 0
      push_this_context
      send sender 0
      send isDead 0
      jump_if_true bad
      push_ivar 0
      push_int 1
      send tempAt: 1
      return_top
    bad:
      push_int -1
      return_top
    end
    method Probe ctx temps=0
      push_ivar 0
      return_top
    end
    """ + runOf("""
      push_lit @Probe
      send basicNew 0
      store_temp 2
      push_temp 2
      push_int 5
      send grab: 1
      push_temp 2
      send ctx 0
      send isDead 0
      jump_if_false bad
      push_temp 2
      send ctx 0
      push_int 2
      send tempAt: 1
      add
      return_top
    bad:
      push_int -1
      return_top
    """, temps: 1))
    defer { h.destroy() }
    // tempAt: 1 live (the argument 5); after the return the Context is
    // dead and keeps its temps (tempAt: 2 = 77).
    #expect(try h.value() == 5 + 77)
    #expect(h.interpreter.counters.contextsMaterialized == 1)  // the second push_this_context finds it
}

// MARK: - exceptions

private let excSrc = """
class T Object 0
; [ExcA new tag: 3; signal + 1] on: ExcA do: [:e | e return: e tag * 10]
method T returning temps=0
  push_closure prot 0
  push_lit @ExcA
  push_closure hand 0
  send on:do: 2
  return_top
block prot args=0 copied=0 temps=0
  push_lit @ExcA
  send basicNew 0
  push_int 3
  send tag: 1
  send signal 0
  push_int 1
  add
  block_return
block hand args=1 copied=0 temps=0
  push_temp 0
  push_temp 0
  send tag 0
  push_int 10
  mul
  send return: 1
  block_return
end
; [(ExcA new signal) + 1] on: ExcA do: [:e | e resume: 41]  -> 42
method T resuming temps=0
  push_closure prot 0
  push_lit @ExcA
  push_closure hand 0
  send on:do: 2
  return_top
block prot args=0 copied=0 temps=0
  push_lit @ExcA
  send basicNew 0
  send signal 0
  push_int 1
  add
  block_return
block hand args=1 copied=0 temps=0
  push_temp 0
  push_int 41
  send resume: 1
  block_return
end
; outer handler for ExcB, inner for ExcA: an ExcB passes the inner one;
; an ensure block between runs when the outer handler returns.
method T nested temps=0
  push_closure outer 0
  push_lit @ExcB
  push_closure hand 0
  send on:do: 2
  push_nil
  push_int 2
  send globalAt: 1
  add
  return_top
block outer args=0 copied=0 temps=0
  push_closure inner 0
  push_lit @ExcA
  push_closure never 0
  send on:do: 2
  block_return
block inner args=0 copied=0 temps=0
  push_closure raise 0
  push_closure mark 0
  send ensure: 1
  block_return
block raise args=0 copied=0 temps=0
  push_lit @ExcB
  send basicNew 0
  send signal 0
  block_return
block mark args=0 copied=0 temps=0
  push_nil
  push_int 2
  push_lit 1000
  send globalAt:put: 2
  block_return
block never args=1 copied=0 temps=0
  push_int -99
  block_return
block hand args=1 copied=0 temps=0
  push_int 7
  block_return
end
method UndefinedObject globalAt: temps=0 prim=14
end
method UndefinedObject globalAt:put: temps=0 prim=15
end
"""

@Test func onDoCatchesASignalAndReturnsFromTheHandlerContext() throws {
    let h = try omHarness(excSrc + runOf(" push_lit @T\n send basicNew 0\n send returning 0\n return_top"))
    defer { h.destroy() }
    #expect(try h.value() == 30)
}

@Test func aResumedSignalAnswersOnTheSignalingStack() throws {
    let h = try omHarness(excSrc + runOf(" push_lit @T\n send basicNew 0\n send resuming 0\n return_top"))
    defer { h.destroy() }
    #expect(try h.value() == 42)
}

@Test func anOuterHandlerRunsAndTheEnsureBlockBetweenRuns() throws {
    let h = try omHarness(excSrc + runOf("""
      push_nil
      push_int 2
      push_int 0
      send globalAt:put: 2
      pop
      push_lit @T
      send basicNew 0
      send nested 0
      return_top
    """))
    defer { h.destroy() }
    // the outer handler answers 7 from on:do:, the ensure block set global 2
    #expect(try h.value() == 1007)
    #expect(h.stack.guardIntact)
}
