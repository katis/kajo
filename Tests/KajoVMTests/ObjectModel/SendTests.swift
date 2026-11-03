// Message sends of ADR 0009 section 11: super through the method's
// defining class, perform: and its arities, respondsTo:, class-side
// methods through classic metaclasses, method installation with the cache
// flush, the special sends' fast paths and fallbacks, the extension prefix.

import Testing
@testable import KajoVM

private let hierarchy = """
class A Object 0
class B A 0
class C B 0
method A foo temps=0
  push_int 1
  return_top
end
method B foo temps=0
  push_self
  send_super foo 0
  push_int 10
  add
  return_top
end
method C foo2 temps=0
  push_self
  send foo 0
  return_top
end
"""

/// The rule: `super` looks up from the superclass of the method's class.
/// `C new foo` runs B>>foo, whose super send must reach A>>foo (1 + 10),
/// not B>>foo again (the receiver's class's superclass is B: with the
/// broken variant the send recurses until the stack overflows).
@Test(arguments: [false, true])
func superLooksUpFromTheMethodsClass(_ broken: Bool) throws {
    var sw = TestSwitches()
    sw.superFromReceiverClass = broken
    let h = try omHarness(hierarchy + runOf(" push_lit @C\n send basicNew 0\n send foo2 0\n return_top"),
                          stackWords: 4096, switches: sw)
    defer { h.destroy() }
    if broken {
        #expect(h.error()?.kind == .stackOverflow)
        return
    }
    #expect(try h.value() == 11)
    #expect(h.interpreter.counters.superSends == 1)
}

@Test func performAndItsAritiesAndRespondsTo() throws {
    let h = try omHarness("""
    class P Object 0
    method P a temps=0
      push_int 1
      return_top
    end
    method P b: temps=0
      push_temp 0
      return_top
    end
    method P c:d: temps=0
      push_temp 0
      push_temp 1
      mul
      return_top
    end
    """ + runOf("""
      push_lit @P
      send basicNew 0
      store_temp 2
      push_temp 2
      push_lit #a
      send perform: 1
      push_temp 2
      push_lit #b:
      push_int 20
      send perform:with: 2
      add
      push_temp 2
      push_lit #c:d:
      push_int 3
      push_int 100
      send perform:with:with: 3
      add
      push_temp 2
      push_lit #c:d:
      push_lit @Array
      push_int 2
      send new: 1
      dup
      push_int 1
      push_int 7
      at_put
      pop
      dup
      push_int 2
      push_lit 1000
      at_put
      pop
      send perform:withArguments: 2
      add
      push_temp 2
      push_lit #c:d:
      send respondsTo: 1
      jump_if_false bad
      push_temp 2
      push_lit #zork
      send respondsTo: 1
      jump_if_true bad
      return_top
    bad:
      push_int -1
      return_top
    """, temps: 1))
    defer { h.destroy() }
    #expect(try h.value() == 1 + 20 + 300 + 7000)
    #expect(h.interpreter.counters.performs == 4)
}

@Test func aPerformWithTheWrongArityFails() throws {
    let h = try omHarness(runOf(" push_nil\n push_lit #foo:\n send perform: 1\n return_top"))
    defer { h.destroy() }
    #expect(h.error()?.kind == .primitiveFailed)
}

@Test func classSideMethodsAndMetaclasses() throws {
    let h = try omHarness("""
    class Shape Object 1 meta=1
    class Square Shape 1 meta=1
    method Shape class make temps=0
      push_self
      send basicNew 0
      return_top
    end
    method Shape class count temps=0
      push_ivar 5
      is_nil
      jump_if_false has
      push_int 0
      store_ivar 5
    has:
      push_ivar 5
      push_int 1
      add
      store_ivar 5
      push_ivar 5
      return_top
    end
    """ + runOf("""
      push_lit @Square
      send make 0
      class_of
      push_lit @Square
      identical
      jump_if_false bad
      push_lit @Square
      class_of
      class_of
      push_lit @Metaclass
      identical
      jump_if_false bad
      push_lit @Shape
      send count 0
      pop
      push_lit @Shape
      send count 0
      return_top
    bad:
      push_int -1
      return_top
    """))
    defer { h.destroy() }
    // class-side methods are inherited (Square make), class instance
    // variables work, Square class class is Metaclass
    #expect(try h.value() == 2)
    let sq = try #require(h.image.classIndex(named: "Square"))
    #expect(h.image.className(h.image.metaclassIndex(of: sq)) == "Square class")
}

@Test func theSpecialSendsFastPathsAndFallbacks() throws {
    let h = try omHarness("""
    class Bag Object 0
    method Bag size temps=0
      push_int 40
      return_top
    end
    method Bag at: temps=0
      push_temp 0
      return_top
    end
    """ + runOf("""
      push_lit @Array
      push_int 3
      send new: 1
      store_temp 2
      push_temp 2
      push_int 2
      push_int 5
      at_put
      pop
      push_temp 2
      push_int 2
      at
      push_temp 2
      size
      add
      push_lit @Bag
      send basicNew 0
      size
      add
      push_lit @Bag
      send basicNew 0
      push_int 100
      at
      add
      push_nil
      is_nil
      jump_if_false bad
      push_int 3
      not_nil
      jump_if_false bad
      push_int 3
      push_int 4
      ne
      jump_if_false bad
      push_int 7
      push_int 2
      int_div
      add
      push_int -7
      push_int 2
      mod
      add
      push_int 12
      push_int 4
      div
      add
      return_top
    bad:
      push_int -1
      return_top
    """, temps: 1))
    defer { h.destroy() }
    // 5 + 3 + 40 + 100 + 3 (7 // 2) + 1 (-7 \\\\ 2) + 3 (12 / 4)
    #expect(try h.value() == 155)
}

@Test func theExtensionPrefixReachesLiteralsPast255() throws {
    var body = ""
    for i in 0..<300 { body += " push_lit \(1000 + i)\n pop\n" }
    body += " push_lit 1299\n push_lit 1000\n add\n return_top"
    let h = try omHarness(runOf(body))
    defer { h.destroy() }
    #expect(try h.value() == 2299)
    let m = try #require(h.image.lookup(WellKnown.undefinedObject, h.image.symbol("run:of:")!))
    let bytes = h.om.bytes(of: h.om.load(m, MethodLayout.bytecodes))
    #expect(bytes.contains(Opcode.ext.rawValue))
}

/// Installing a method in a running image: the next send finds it (the
/// lookup cache was flushed after the install, which ran in a stop).
@Test func anInstalledMethodIsFoundByTheNextSend() throws {
    let h = try omHarness("""
    class Q Object 0
    class R Object 0
    method Q answer temps=0
      push_int 1
      return_top
    end
    method R answer temps=0
      push_int 2
      return_top
    end
    method R steal temps=0
      push_int 3
      return_top
    end
    method UndefinedObject ask temps=0
      push_lit @Q
      send basicNew 0
      send answer 0
      return_top
    end
    """ + runOf(" push_int 0\n return_top"))
    defer { h.destroy() }
    #expect(try h.value("ask", []) == 1)
    // Install R>>steal into R as #answer: a method compiled for R only.
    let om = h.om, img = h.image
    let r = om.classOop(img.classIndex(named: "R")!), q = om.classOop(img.classIndex(named: "Q")!)
    let steal = try #require(img.lookup(img.classIndex(named: "R")!, img.symbol("steal")!))
    // Q refuses R's method (compiled for another class).
    let m = h.interpreter.machine
    #expect(objectModelPrimitive(97, m, PrimitiveCall(receiver: q, argc: 2, arg0: img.symbol("answer")!, arg1: steal)) == .none)
    #expect(objectModelPrimitive(97, m, PrimitiveCall(receiver: r, argc: 2, arg0: img.symbol("answer")!, arg1: steal)) == r)
    #expect(h.interpreter.counters.methodsInstalled == 1)
    #expect(try h.value("ask", []) == 1)
    #expect(try img.lookup(img.classIndex(named: "R")!, img.symbol("answer")!) == steal)
    #expect(objectModelPrimitive(98, m, PrimitiveCall(receiver: r, argc: 1, arg0: img.symbol("answer")!, arg1: .none)) == r)
    #expect(img.lookup(img.classIndex(named: "R")!, img.symbol("answer")!) == nil)
}
