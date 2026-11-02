import Testing
@testable import KajoVM

/// Ported from object-representation: fib 20 through lib.kasm's `fibx`.
@Test func smallProgramRuns() throws {
    let h = try Harness(runOf(" push_int 20\n send fibx 0\n push_temp 0\n add\n return_top"))
    defer { h.destroy() }
    #expect(try h.value() == 6765)
    #expect(try h.value("run:of:", [100, 1]) == 6865)  // arguments are temps 0 and 1
}

@Test func loopsTempsAndJumps() throws {
    // sum 1..100 with a backward jump
    let h = try Harness(runOf("""
      push_int 0
      store_temp 2
      push_int 1
      store_temp 3
    loop:
      push_temp 3
      push_lit 100
      le
      jump_if_false done
      push_temp 2
      push_temp 3
      add
      store_temp 2
      push_temp 3
      push_int 1
      add
      store_temp 3
      jump loop
    done:
      push_temp 2
      return_top
    """, temps: 2))
    defer { h.destroy() }
    #expect(try h.value() == 5050)
}

@Test func instanceVariablesSelfAndReturns() throws {
    let h = try Harness("""
    class P Object 2
    method P x:y: temps=0
      push_temp 0
      store_ivar 0
      push_temp 1
      store_ivar 1
      return_self
    end
    method P sum temps=0
      push_ivar 0
      push_ivar 1
      add
      return_top
    end
    method P me temps=0
      push_self
      return_top
    end
    """ + runOf("""
      push_lit @P
      send basicNew 0
      push_int 30
      push_int 12
      send x:y: 2
      store_temp 2
      push_temp 2
      push_temp 2
      send me 0
      identical
      jump_if_false bad
      push_temp 2
      send sum 0
      return_top
    bad:
      push_int -1
      return_top
    """, temps: 1))
    defer { h.destroy() }
    #expect(try h.value() == 42)
}

@Test func pushConstantsAndDup() throws {
    let h = try Harness(runOf("""
      push_nil
      push_nil
      identical
      push_true
      identical
      jump_if_false bad
      push_false
      jump_if_true bad
      push_int -7
      dup
      add
      return_top
    bad:
      push_int 0
      return_top
    """))
    defer { h.destroy() }
    #expect(try h.value() == -14)
}

/// Special sends: SmallInteger fast path for each, comparison results are
/// the true and false objects.
@Test(arguments: [
    ("add", 17, 5, 22), ("sub", 17, 5, 12), ("mul", 17, -5, -85),
    ("lt", 3, 5, 1), ("lt", 5, 3, 0), ("gt", 5, 3, 1), ("gt", 3, 3, 0),
    ("le", 3, 3, 1), ("le", 4, 3, 0), ("ge", 3, 3, 1), ("ge", 2, 3, 0),
    ("eq", 3, 3, 1), ("eq", 3, 4, 0), ("identical", 3, 3, 1), ("identical", 3, 4, 0),
] as [(String, Int64, Int64, Int64)])
func specialSends(_ op: String, _ a: Int64, _ b: Int64, _ expected: Int64) throws {
    let h = try Harness(runOf("""
      push_lit \(a)
      push_lit \(b)
      \(op)
      dup
      push_true
      identical
      jump_if_true t
      dup
      push_false
      identical
      jump_if_true f
      return_top
    t:
      push_int 1
      return_top
    f:
      push_int 0
      return_top
    """))
    defer { h.destroy() }
    #expect(try h.value() == expected)
    #expect(h.interpreter.counters.specialSendFallbacks == 0)
}

/// Overflow and non-SmallInteger operands are real sends of the special
/// selector, never a trap.
@Test func overflowAndOtherReceiversAreRealSends() throws {
    let h = try Harness("""
    method SmallInteger + temps=0
      push_int 42
      return_top
    end
    method SmallInteger * temps=0
      push_int 43
      return_top
    end
    method UndefinedObject < temps=0
      push_temp 0
      return_top
    end
    method UndefinedObject = temps=0
      push_int 44
      return_top
    end
    """ + runOf("""
      push_lit 4611686018427387903
      push_int 1
      add
      push_lit 4611686018427387903
      push_int 2
      mul
      add
      push_nil
      push_int 100
      lt
      add
      push_int 1
      push_nil
      add
      add
      push_nil
      push_nil
      eq
      add
      return_top
    """))
    defer { h.destroy() }
    // + overflows: 42; * overflows: 43; 42 + 43 = 85 on the fast path;
    // nil < 100: 100; 1 + nil: 42 (SmallInteger>>+); nil = nil: 44
    #expect(try h.value() == 42 + 43 + 100 + 42 + 44)
    #expect(h.interpreter.counters.specialSendFallbacks == 5)
}

@Test func subtractionOverflowAtTheBottomOfTheRange() throws {
    let h = try Harness("""
    method SmallInteger - temps=0
      push_int 9
      return_top
    end
    """ + runOf("""
      push_lit -4611686018427387904
      push_int 1
      sub
      return_top
    """))
    defer { h.destroy() }
    #expect(try h.value() == 9)
}

@Test func sendsCountersAndTheLookupCache() throws {
    let h = try Harness(runOf(" push_int 15\n send fibx 0\n return_top"))
    defer { h.destroy() }
    #expect(try h.value() == 610)
    let c = h.interpreter.counters
    #expect(c.sends == 1973)            // fibx 15 sends fibx 1973 times; the host's entry is not a send
    #expect(c.cacheMisses <= 2)
    #expect(c.primitiveCalls == 0 && c.errors == 0)
}

@Test func interpreterRunsAgainOnTheSameStack() throws {
    let h = try Harness(runOf(" push_temp 0\n push_temp 1\n mul\n return_top"))
    defer { h.destroy() }
    for i: Int64 in 0..<10 { #expect(try h.value("run:of:", [i, 7]) == 7 * i) }
}

@Test func primitiveFailureRunsTheMethodBody() throws {
    let h = try Harness("""
    class Box Object 0
    method Box at: temps=0 prim=1
      push_int -1
      return_top
    end
    """ + runOf("""
      push_lit @Box
      send basicNew 0
      push_int 5
      send at: 1
      return_top
    """), base: ["prelude"])
    defer { h.destroy() }
    #expect(try h.value() == -1)
    #expect(h.interpreter.counters.primitiveFailures == 1)
}

/// The host's send can land on a primitive: its result comes back without
/// a frame ever being pushed.
@Test func theHostCanSendToAPrimitive() throws {
    let h = try Harness("", base: ["prelude"])
    defer { h.destroy() }
    let cls = try h.interpreter.run(on: h.stack, receiver: h.image.nilObject, selector: "class", arguments: []).get()
    #expect(cls == h.om.classOop(WellKnown.undefinedObject))
    let r = h.interpreter.run(on: h.stack, receiver: Oop(smallInteger: 7), selector: "//", arguments: [Oop(smallInteger: 0)])
    guard case .failure(let e) = r else { Issue.record("7 // 0 answered"); return }
    #expect(e.kind == .primitiveFailed && e.primitive == 6)
}

/// A unary doesNotUnderstand: at the deepest operand-stack slot of the
/// last frame that fits replaces nothing and pushes the Message: the stack
/// must have room for it.
@Test func aUnaryDoesNotUnderstandAtTheTopOfTheStack() throws {
    let src = """
    method SmallInteger doesNotUnderstand: temps=0
      push_int 5
      return_top
    end
    method UndefinedObject deep: temps=0
      push_temp 0
      push_int 0
      eq
      jump_if_true bottom
      push_nil
      push_temp 0
      push_int 1
      sub
      send deep: 1
      return_top
    bottom:
      push_nil
      send bottom 0
      return_top
    end
    ; maxStack 1, reached at the unary send
    method UndefinedObject bottom temps=0
      push_int 1
      send foo 0
      return_top
    end
    """
    // every stack size from tight to roomy: some frame ends exactly at the top
    for words in 64...96 {
        let h = try Harness(src, base: [], stackWords: words)
        defer { h.destroy() }
        for depth: Int64 in 0...12 {
            switch h.run("deep:", [depth]) {
            case .success(let v): #expect(v == Oop(smallInteger: 5))
            case .failure(let e): #expect(e.kind == .stackOverflow)
            }
            #expect(h.stack.guardIntact, "stack of \(words) words, depth \(depth)")
        }
    }
}
