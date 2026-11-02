import Testing
@testable import KajoVM

/// A test per VMError kind. Each returns an error value to the caller; the
/// process never exits and the stack stays for inspection.

@Test func doesNotUnderstandIsAnError() throws {
    let h = try Harness(runOf(" push_int 3\n push_int 4\n send foo: 1\n return_top"), base: [])
    defer { h.destroy() }
    let e = try #require(h.error())
    #expect(e.kind == .doesNotUnderstand)
    #expect(e.selector == "foo:" && e.receiverClass == "SmallInteger")
    #expect(e.method == "UndefinedObject>>run:of:" && e.pc == 4)
    #expect(h.interpreter.counters.errors == 1)
    #expect("\(e)".contains("doesNotUnderstand") && "\(e)".contains("foo:"))
}

@Test func doesNotUnderstandIsSentWithAMessageWhenTheClassHasIt() throws {
    let h = try Harness("""
    method SmallInteger doesNotUnderstand: temps=0
      push_temp 0
      return_top
    end
    """ + runOf(" push_int 3\n push_int 4\n push_nil\n send foo:bar: 2\n return_top"), base: [])
    defer { h.destroy() }
    let msg = try h.run().get()
    let om = h.om
    #expect(om.classIndex(of: msg) == WellKnown.message)
    #expect(om.load(msg, MessageLayout.selector) == h.image.symbol("foo:bar:"))
    let args = om.load(msg, MessageLayout.arguments)
    #expect(om.classIndex(of: args) == WellKnown.array && om.count(of: args) == 2)
    #expect(om.load(args, 0) == Oop(smallInteger: 4) && om.load(args, 1) == h.image.nilObject)
}

@Test func aNonBooleanJumpIsAnError() throws {
    let h = try Harness(runOf(" push_int 1\n jump_if_true x\nx:\n push_nil\n return_top"), base: [])
    defer { h.destroy() }
    let e = try #require(h.error())
    #expect(e.kind == .mustBeBoolean && e.pc == 2 && e.receiverClass == "SmallInteger")
}

@Test func aFailedPrimitiveWithoutABodyIsAnError() throws {
    let h = try Harness(runOf(" push_lit @Array\n push_int -1\n send new: 1\n return_top"), base: ["prelude"])
    defer { h.destroy() }
    let e = try #require(h.error())
    #expect(e.kind == .primitiveFailed && e.primitive == 3 && e.selector == "new:" && e.receiverClass == "Class")
}

@Test func deepRecursionIsAStackOverflow() throws {
    let h = try Harness("""
    method UndefinedObject down: temps=0
      push_nil
      push_temp 0
      push_int 1
      add
      send down: 1
      return_top
    end
    """ + runOf(" push_nil\n push_int 0\n send down: 1\n return_top"), base: [], stackWords: 4096)
    defer { h.destroy() }
    let e = try #require(h.error())
    #expect(e.kind == .stackOverflow && e.selector == "down:")
    // the frames are still there: the stack was left for inspection
    let frames = h.interpreter.backtrace(h.stack)
    #expect(frames.count > 400 && frames.first == "UndefinedObject>>down:" && frames.last == "UndefinedObject>>run:of:")
    // and the stack can be used again
    #expect(h.error()?.kind == .stackOverflow)
}

@Test func runningOutOfHeapIsAnError() throws {
    let h = try Harness(runOf("""
    loop:
      push_lit @Array
      push_int 100
      send new: 1
      dup
      push_int 1
      push_temp 2
      send at:put: 2
      pop
      store_temp 2
      jump loop
    """, temps: 1), base: ["prelude"], heapBlocks: 16)
    defer { h.destroy() }
    let e = try #require(h.error())
    #expect(e.kind == .outOfMemory && e.selector == "new:")
    #expect(h.om.counters.compactions >= 1)  // it tried everything first
}

/// become: can give a running method's receiver fewer slots than its class
/// declares; the instance variable access is checked, not trusted.
@Test func aSlotOutsideTheReceiverIsAnError() throws {
    let h = try Harness("""
    class P Object 3
    class Q Object 0
    method P shrinkAndRead temps=0
      push_self
      push_lit @Q
      send basicNew 0
      send become: 1
      pop
      push_ivar 2
      return_top
    end
    method P shrinkAndWrite temps=0
      push_self
      push_lit @Q
      send basicNew 0
      send become: 1
      pop
      push_int 1
      store_ivar 2
      return_self
    end
    method UndefinedObject read temps=0
      push_lit @P
      send basicNew 0
      send shrinkAndRead 0
      return_top
    end
    method UndefinedObject write temps=0
      push_lit @P
      send basicNew 0
      send shrinkAndWrite 0
      return_top
    end
    """)
    defer { h.destroy() }
    let r = try #require(h.error("read", []))
    #expect(r.kind == .invalidSlotAccess && r.method == "P>>shrinkAndRead")
    let w = try #require(h.error("write", []))
    #expect(w.kind == .invalidSlotAccess && w.method == "P>>shrinkAndWrite")
}

/// The loader never produces an unknown opcode; a corrupted method body is
/// still an error value, not a crash.
@Test func anUnknownOpcodeIsAnError() throws {
    let h = try Harness(runOf(" push_int 1\n return_top"), base: [])
    defer { h.destroy() }
    let m = try #require(h.image.lookup(WellKnown.undefinedObject, h.image.symbol("run:of:")!))
    h.om.storeByte(h.om.load(m, MethodLayout.bytecodes), 2, 0xEE)
    let e = try #require(h.error())
    #expect(e.kind == .invalidBytecode && e.pc == 2)
}
