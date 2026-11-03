// Read-only objects (ADR 0009 section 9): header bit 50, checked in every
// store path; a refused store sends attemptToModify:at:value: to the
// object (its answer replaces a primitive's, and is dropped after a store
// bytecode); method literals are read-only.

import Testing
@testable import KajoVM

private let readOnlySrc = """
class Cell Object 2
method Cell x: temps=0
  push_temp 0
  store_ivar 0
  push_int 1
  return_top
end
method Cell x temps=0
  push_ivar 0
  return_top
end
; the kernel's handler: count the refusals in slot 1 of global 3 (an Array)
method Object attemptToModify:at:value: temps=0
  push_nil
  push_int 3
  send globalAt: 1
  push_int 1
  push_nil
  push_int 3
  send globalAt: 1
  push_int 1
  at
  push_temp 1
  add
  at_put
  pop
  push_int -5
  return_top
end
method UndefinedObject globalAt: temps=0 prim=14
end
method UndefinedObject globalAt:put: temps=0 prim=15
end
method UndefinedObject setUp temps=0
  push_nil
  push_int 3
  push_lit @Array
  push_int 1
  send new: 1
  dup
  push_int 1
  push_int 0
  at_put
  pop
  send globalAt:put: 2
  return_top
end
method UndefinedObject refusals temps=0
  push_nil
  push_int 3
  send globalAt: 1
  push_int 1
  at
  return_top
end
"""

/// The rule: `store_ivar` into a read-only object stores nothing and sends
/// attemptToModify:at:value: (index 1-based), whose answer is dropped;
/// cleared, the store happens.
@Test func aStoreIntoAReadOnlyObjectSendsAttemptToModify() throws {
    let h = try omHarness(readOnlySrc + runOf("""
      push_nil
      send setUp 0
      pop
      push_lit @Cell
      send basicNew 0
      store_temp 2
      push_temp 2
      push_int 7
      send x: 1
      pop
      push_temp 2
      push_true
      send setReadOnly: 1
      pop
      push_temp 2
      push_int 8
      send x: 1
      push_temp 2
      send x 0
      push_int 10
      mul
      add
      push_temp 2
      push_false
      send setReadOnly: 1
      pop
      push_temp 2
      push_int 9
      send x: 1
      pop
      push_temp 2
      send x 0
      push_int 100
      mul
      add
      return_top
    """, temps: 1))
    defer { h.destroy() }
    // x: answered 1 after the refused store (the handler's -5 dropped);
    // x stayed 7; then 9 once writable
    #expect(try h.value() == 1 + 70 + 900)
    #expect(try h.value("refusals", []) == 1)  // index 1
    #expect(h.interpreter.counters.readOnlyRefusals == 1)
}

@Test func storePrimitivesRefuseReadOnlyObjects() throws {
    let h = try omHarness(readOnlySrc + runOf("""
      push_nil
      send setUp 0
      pop
      push_lit @Array
      push_int 3
      send new: 1
      store_temp 2
      push_temp 2
      push_true
      send setReadOnly: 1
      pop
      push_temp 2
      push_int 2
      push_int 4
      send at:put: 2
      push_temp 2
      push_int 3
      push_int 4
      at_put
      add
      push_temp 2
      push_int 1
      push_int 4
      send instVarAt:put: 2
      add
      push_temp 2
      push_int 1
      push_int 1
      push_lit @Array
      push_int 1
      send new: 1
      push_int 1
      send replaceFrom:to:with:startingAt: 4
      pop
      push_temp 2
      push_int 2
      at
      is_nil
      jump_if_false bad
      return_top
    bad:
      push_int 0
      return_top
    """, temps: 1))
    defer { h.destroy() }
    // three refusals answered -5 each (at:put: through the primitive and
    // through the special send's fallback, instVarAt:put:); nothing stored
    #expect(try h.value() == -15)
    #expect(try h.value("refusals", []) == 2 + 3 + 1 + 1)
}

@Test func methodLiteralsAreReadOnly() throws {
    let h = try omHarness(readOnlySrc + runOf("""
      push_nil
      send setUp 0
      pop
      push_lit 'text'
      send isReadOnly 0
      jump_if_false bad
      push_lit #sym
      send isReadOnly 0
      jump_if_false bad
      push_lit 1.0e100
      send isReadOnly 0
      jump_if_false bad
      push_int 1
      return_top
    bad:
      push_int 0
      return_top
    """))
    defer { h.destroy() }
    #expect(try h.value() == 1)
    let m = try #require(h.image.lookup(WellKnown.undefinedObject, h.image.symbol("run:of:")!))
    #expect(h.om.isReadOnly(h.om.load(m, MethodLayout.literals)) && h.om.isReadOnly(h.om.load(m, MethodLayout.bytecodes)))
}

@Test func becomeAndReshapeRefuseReadOnlyObjects() throws {
    let h = try omHarness(readOnlySrc + runOf(" push_int 0\n return_top"))
    defer { h.destroy() }
    let m = h.interpreter.machine
    let a = m.allocate(WellKnown.array, slots: 1), b = m.allocate(WellKnown.array, slots: 1, keeping: a)
    h.om.setReadOnly(a, true)
    #expect(!m.become(a, b))
    h.om.setReadOnly(a, false)
    #expect(m.become(a, b))
    let cell = try #require(h.image.classIndex(named: "Cell"))
    let c = m.allocate(cell, slots: 2)
    h.om.setReadOnly(c, true)
    #expect(throws: ReshapeError.readOnlyInstance) {
        try h.om.reshape(classIndex: cell, namedSlots: 2, layout: [0, 1, nil], fill: h.image.nilObject)
    }
}
