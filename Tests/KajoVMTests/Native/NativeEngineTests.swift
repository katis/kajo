import Foundation
import Testing
import KajoAOT
@testable import KajoVM

// AOT 1 (docs/modules/aot.md, Tests): the engine switches, the binding and
// the broken variants. The whole interpreter suite also runs natively
// (KAJO_NATIVE_HARNESS=1, KAJO_NATIVE_RUNTIME=1).

/// Two versions of one program: `callee:` and `outer` differ in their
/// bytecodes only (the same literals, so every other method and every oop
/// is the same in both images). A module generated from version A binds
/// in version B every method but those two.
func switchProgram(_ version: Int) -> String {
    """
    method UndefinedObject callee: temps=0
      push_temp 0
      push_int \(version)
      add
      return_top
    end
    method UndefinedObject spin: temps=1
      push_int 0
      store_temp 1
    loop:
      push_temp 1
      push_temp 0
      lt
      jump_if_false done
      push_temp 1
      push_int 1
      add
      store_temp 1
      jump loop
    done:
      push_temp 1
      return_top
    end
    method UndefinedObject outer temps=0
    \(version == 2 ? "  push_int 7\n  pop" : "")
      push_nil
      push_lit 200000
      send spin: 1
      return_top
    end
    method UndefinedObject root temps=0
      push_nil
      push_int 5
      send callee: 1
      push_nil
      send outer 0
      add
      return_top
    end
    method Object same temps=0
      push_int 3
      return_top
    end
    method UndefinedObject same2 temps=0
      push_int 3
      return_top
    end
    """
}

/// The module generated from `src` loaded the way `Runtime` loads it.
func moduleGenerated(from src: String, options: AOTOptions = AOTOptions(), edit: (String) -> String = { $0 }) throws -> NativeModule {
    let rt = try Runtime(src, background: 1, start: false, native: false)
    let out = NativeTest.source(for: rt.image, options: options)
    rt.stop(verifyHeap: false)
    return try NativeTest.compile(edit(out.source), name: "kajo-native-generated")
}

@Test func anUnboundCalleeRunsInterpretedAndItsReturnSwitchesBack() throws {
    let module = try moduleGenerated(from: switchProgram(1))
    let rt = try Runtime(switchProgram(2), background: 1, native: false, module: module)
    let p = rt.spawn("root")
    #expect(rt.waitAllTerminated())
    // The new bytecodes' answers: 5 + 2 and 200000 (outer runs as changed).
    #expect(rt.result(p) == 200_007)
    let r = try #require(rt.vm.nativeReport)
    #expect(r.refused == nil && r.unboundNoMatch == 2 && r.bound == r.methods - 2, "\(r)")
    let n = rt.vm.nativeCounters
    // Native to interpreter at the unbound callee (its frame marked), back
    // at its return; the bound `spin:` activated by the interpreted `outer`
    // runs interpreted until a budget check, then natively.
    #expect(n.toInterpreterUnbound >= 2 && n.markersSet >= 2 && n.toNativeAtReturn >= 2 && n.toNativeAtPoll >= 1, "\(n)")
    rt.stop()
}

@Test func aMethodWhoseBytecodesChangedIsNotBoundAndAnswersRight() throws {
    let module = try moduleGenerated(from: switchProgram(1))
    let rt = try Runtime(switchProgram(2), background: 1, native: false, module: module)
    let p = rt.spawn("callee:", [Oop(smallInteger: 40)])
    #expect(rt.waitAllTerminated())
    #expect(rt.result(p) == 42)
    rt.stop()
}

@Test func aModuleOfAnotherVersionOrLayoutIsRefusedWhole() throws {
    for (what, edit) in [("interface version", { (s: String) in s.replacingOccurrences(of: "FORMAT_VERSION, LAYOUT_HASH0, LAYOUT_HASH1", with: "FORMAT_VERSION + 1, LAYOUT_HASH0, LAYOUT_HASH1") }),
                         ("layout hash", { (s: String) in s.replacingOccurrences(of: "FORMAT_VERSION, LAYOUT_HASH0, LAYOUT_HASH1", with: "FORMAT_VERSION, LAYOUT_HASH0 ^ 1, LAYOUT_HASH1") })] {
        let module = try moduleGenerated(from: switchProgram(1), edit: edit)
        let rt = try Runtime(switchProgram(1), background: 1, native: false, module: module)
        let r = try #require(rt.vm.nativeReport)
        #expect(r.refused?.contains(what) == true && r.bound == 0, "\(r)")
        let p = rt.spawn("root")
        #expect(rt.waitAllTerminated())
        #expect(rt.result(p) == 200_006)
        #expect(rt.vm.nativeCounters.entries == 0)
        rt.stop()
    }
}

@Test func methodsOfEqualContentShareOneGroupAndTheBindingRootsThem() throws {
    let rt = try Runtime(switchProgram(1), background: 1, native: true)
    let r = try #require(rt.vm.nativeReport)
    // `Object>>same` and `UndefinedObject>>same2` (and the prelude's equal
    // methods) share groups.
    #expect(r.groupsUsed < r.bound, "\(r)")
    #expect(rt.image.om.rootCount >= r.bound)
    rt.vm.collect()
    let p = rt.spawn("root")
    #expect(rt.waitAllTerminated())
    #expect(rt.result(p) == 200_006)
    rt.stop()
}

/// Rule 7's drift detector: the native engine's send count is the
/// interpreter's, on the same program.
@Test func sendCountsAreEqualInBothEngines() throws {
    func sends(_ native: Bool) throws -> UInt64 {
        let rt = try Runtime(switchProgram(1), background: 1, native: native)
        let p = rt.spawn("root")
        #expect(rt.waitAllTerminated())
        #expect(rt.result(p) == 200_006)
        let s = rt.vm.interpreterCounters.sends
        rt.stop()
        return s
    }
    #expect(try sends(true) == sends(false))
}

/// A broken variant as a test switch: a generator that does not bump the
/// send count. The drift detector above sees it.
@Test func aSendNotCountedIsSeenByTheDriftDetector() throws {
    var o = AOTOptions()
    o.brokenNoSendCount = true
    let broken = try moduleGenerated(from: switchProgram(1), options: o)
    let rt = try Runtime(switchProgram(1), background: 1, native: false, module: broken)
    let p = rt.spawn("root")
    #expect(rt.waitAllTerminated())
    let a = rt.vm.interpreterCounters.sends
    #expect(rt.result(p) == 200_006)
    rt.stop()
    let ok = try Runtime(switchProgram(1), background: 1, native: false)
    let q = ok.spawn("root")
    #expect(ok.waitAllTerminated())
    let b = ok.vm.interpreterCounters.sends
    #expect(ok.result(q) == 200_006)
    ok.stop()
    #expect(a < b, "the uncounted sends: \(a) against \(b)")
}

/// An accumulator held in an operand slot across backward jumps whose
/// polls preempt the Process: the slot must be in the frame at every poll
/// (rule 6: operands are flushed before every call into the VM), or the
/// resumed Process reads a stale one.
let operandAcrossPolls = """
method UndefinedObject acc: temps=1
  push_int 0
  push_int 0
  store_temp 1
loop:
  push_temp 1
  push_temp 0
  lt
  jump_if_false done
  push_int 3
  add
  push_temp 1
  push_int 1
  add
  store_temp 1
  jump loop
done:
  return_top
end
"""

@Test func anOperandIsInTheFrameAtEveryPoll() throws {
    let rt = try Runtime(operandAcrossPolls, background: 1, configure: { $0.stress = .preemptEveryPoll }, native: true)
    let p = rt.spawn("acc:", [Oop(smallInteger: 3000)])
    #expect(rt.waitAllTerminated())
    #expect(rt.result(p) == 9000)
    #expect(rt.vm.counters.preemptions > 100 && rt.vm.nativeCounters.entries > 100)
    rt.stop()
}

/// The broken variant: no flush before a backward jump's poll. A preempted
/// Process resumes from the frame's stale slot and answers wrong.
@Test func anOperandLeftInALocalAcrossAPollIsLost() throws {
    var o = AOTOptions()
    o.brokenNoFlushAtPoll = true
    let broken = try moduleGenerated(from: operandAcrossPolls, options: o)
    let rt = try Runtime(operandAcrossPolls, background: 1, configure: { $0.stress = .preemptEveryPoll }, native: false, module: broken)
    let p = rt.spawn("acc:", [Oop(smallInteger: 3000)])
    #expect(rt.waitAllTerminated())
    #expect(rt.vm.result(of: p) != Oop(smallInteger: 9000), "the broken variant went unnoticed")
    rt.stop()
}

/// Every opcode of bytecode set v1 has an emitter in the generator (inline,
/// a special send's slow path, or the VM's own out-of-line code), fused
/// ones through their plain parts, and the interpreter suite's methods use
/// each plain opcode (run natively under KAJO_NATIVE_HARNESS).
@Test func theGeneratorHasNoGap() {
    for op in Opcode.allCases {
        #expect(AOTGenerator.emitter(for: op.base) != nil, "\(op)")
    }
}

/// The deepest stack with a `doesNotUnderstand:` at the top slot, an
/// extended operand and the largest literal index, natively.
@Test func methodsAtTheEncodingLimitsRunNatively() throws {
    var lits = ""
    for i in 0..<300 { lits += "  push_lit \(1000 + i)\n  pop\n" }
    var deep = ""
    for i in 0..<200 { deep += "  push_int \(i % 100)\n" }
    for _ in 0..<199 { deep += "  add\n" }
    let src = """
    method UndefinedObject many temps=200
    \(lits)  push_lit 1299
      store_temp 199
      push_temp 199
      return_top
    end
    method UndefinedObject deep temps=0
    \(deep)  return_top
    end
    method UndefinedObject dnuAtTop temps=0
    \((0..<40).map { _ in "  push_int 1\n" }.joined())  push_nil
      send zork 0
      return_top
    end
    method UndefinedObject doesNotUnderstand: temps=0
      push_int 77
      return_top
    end
    """
    let rt = try Runtime(src, background: 1, native: true)
    let a = rt.spawn("many"), b = rt.spawn("deep"), c = rt.spawn("dnuAtTop")
    #expect(rt.waitAllTerminated())
    #expect(rt.result(a) == 1299)
    #expect(rt.result(b) == Int64((0..<200).reduce(0) { $0 + $1 % 100 }))
    #expect(rt.result(c) == 77)
    #expect(rt.vm.nativeCounters.nativeReturns > 0)
    rt.stop()
}

/// Stack growth inside a native method: deep recursion past the first
/// segment.
@Test func theStackGrowsUnderNativeFrames() throws {
    let src = """
    method UndefinedObject down: temps=0
      push_temp 0
      push_int 0
      eq
      jump_if_false more
      push_int 0
      return_top
    more:
      push_nil
      push_temp 0
      push_int 1
      sub
      send down: 1
      push_int 1
      add
      return_top
    end
    """
    let rt = try Runtime(src, background: 1, native: true)
    let p = rt.spawn("down:", [Oop(smallInteger: 20000)])
    #expect(rt.waitAllTerminated())
    #expect(rt.result(p) == 20000)
    #expect(rt.vm.counters.stackGrowths > 0)
    #expect(rt.vm.nativeCounters.nativeSends > 10000)
    rt.stop()
}

/// Rule 11: a Process that steps runs interpreted. It steps itself into
/// (primitive 158) from a native frame: native code hands its frame to the
/// interpreter, the step stops it at its next poll, the debugger's
/// interrupt turns stepping off, and it goes on natively.
@Test func aSteppedProcessRunsInterpreted() throws {
    let src = """
    method Process primStep:frame: temps=0 prim=158
      push_nil
      return_top
    end
    method Process stopForDebugger temps=0
      push_self
      push_int 0
      push_nil
      send primStep:frame: 2
      return_top
    end
    method UndefinedObject plus: temps=0
      push_temp 0
      push_int 1
      add
      return_top
    end
    method UndefinedObject stepped temps=0
      push_nil
      send activeProcess 0
      push_int 1
      push_this_context
      send primStep:frame: 2
      pop
      push_nil
      push_int 40
      send plus: 1
      push_nil
      push_int 0
      send plus: 1
      add
      return_top
    end
    """
    let rt = try Runtime(src, background: 1, native: true)
    let p = rt.spawn("stepped")
    #expect(rt.waitAllTerminated())
    #expect(rt.result(p) == 42)
    #expect(rt.vm.nativeCounters.toInterpreterStepping >= 1, "\(rt.vm.nativeCounters)")
    #expect(rt.vm.counters[.stepStops] >= 1)
    rt.stop()
}
