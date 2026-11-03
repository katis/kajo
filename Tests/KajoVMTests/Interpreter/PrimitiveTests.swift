import Testing
@testable import KajoVM

/// Each v0 primitive's success case, through a send from Smalltalk.
@Test func primitivesAnswerWhatTheyShould() throws {
    let h = try Harness("""
    class P Object 2
    method Object == temps=0 prim=18
    end
    method Object identityHash temps=0 prim=19
    end
    ; at:put: then at: on an Array (t2) and a ByteArray (t3), class, basicNew: sizes
    method UndefinedObject arrays temps=2
      push_lit @Array
      push_int 5
      send basicNew: 1
      store_temp 0
      push_lit @ByteArray
      push_int 9
      send new: 1
      store_temp 1
      push_temp 0
      push_int 5
      push_int 77
      send at:put: 2
      pop
      push_temp 1
      push_int 9
      push_lit 255
      send at:put: 2
      pop
      push_temp 0
      push_int 5
      send at: 1
      push_temp 1
      push_int 9
      send at: 1
      add
      push_temp 1
      push_int 1
      send at: 1
      add
      return_top
    end
    method UndefinedObject classes temps=0
      push_lit @P
      send basicNew 0
      send class 0
      push_lit @P
      identical
      jump_if_false bad
      push_int 3
      send class 0
      push_lit @SmallInteger
      identical
      jump_if_false bad
      push_int 1
      return_top
    bad:
      push_int 0
      return_top
    end
    method UndefinedObject divisions temps=0
      push_int 17
      push_int 5
      send // 1
      push_int -17
      push_int 5
      send // 1
      push_int 100
      mul
      add
      push_int -17
      push_int 5
      send \\\\ 1
      push_lit 10000
      mul
      add
      push_int 17
      push_int -5
      send \\\\ 1
      push_lit 1000000
      mul
      add
      return_top
    end
    method UndefinedObject globals temps=0
      push_nil
      push_int 3
      push_int 99
      send globalAt:put: 2
      pop
      push_nil
      push_int 3
      send globalAt: 1
      push_nil
      push_int 4
      send globalAt: 1
      push_nil
      identical
      jump_if_false bad
      return_top
    bad:
      push_int 0
      return_top
    end
    method UndefinedObject identity temps=1
      push_lit @P
      send basicNew 0
      store_temp 0
      push_temp 0
      push_temp 0
      send == 1
      jump_if_false bad
      push_temp 0
      push_lit @P
      send basicNew 0
      send == 1
      jump_if_true bad
      push_temp 0
      send identityHash 0
      push_temp 0
      send identityHash 0
      eq
      jump_if_false bad
      push_int 1
      return_top
    bad:
      push_int 0
      return_top
    end
    """)
    defer { h.destroy() }
    #expect(try h.value("arrays", []) == 77 + 255 + 0)
    #expect(try h.value("classes", []) == 1)
    // 17 // 5 = 3; -17 // 5 = -4 (floor); -17 \\ 5 = 3; 17 \\ -5 = -3
    #expect(try h.value("divisions", []) == 3 - 400 + 30_000 - 3_000_000)
    #expect(try h.value("globals", []) == 99)
    #expect(try h.value("identity", []) == 1)
    #expect(h.interpreter.counters.primitiveFailures == 0)
    #expect(h.interpreter.counters.primitiveCalls > 20)
}

/// Every check a primitive makes: each failing call falls into a body that
/// answers -1, so the result counts the failures.
@Test(arguments: [
    ("push_lit @Array\n push_int 3\n send new: 1\n push_int 0\n send at: 1", "index 0"),
    ("push_lit @Array\n push_int 3\n send new: 1\n push_int 4\n send at: 1", "index past the end"),
    ("push_lit @Array\n push_int 3\n send new: 1\n push_nil\n send at: 1", "index not a SmallInteger"),
    ("push_int 3\n push_int 1\n send at: 1", "SmallInteger receiver"),
    ("push_lit @ByteArray\n push_int 3\n send new: 1\n push_int 1\n push_lit 256\n send at:put: 2", "byte out of range"),
    ("push_lit @ByteArray\n push_int 3\n send new: 1\n push_int 1\n push_nil\n send at:put: 2", "byte not an integer"),
    ("push_lit @Array\n push_int -1\n send new: 1", "negative size"),
    ("push_lit @Array\n push_lit 4096\n send new: 1", "larger than a block"),
    ("push_lit @ByteArray\n push_lit 32761\n send new: 1", "bytes larger than a block"),
    ("push_lit @Array\n push_nil\n send new: 1", "size not an integer"),
    ("push_int 3\n send basicNew 0", "basicNew to a non-class"),
    ("push_lit @SmallInteger\n send basicNew 0", "an immediate class"),
    ("push_lit @CompiledMethod\n send basicNew 0", "a structural class"),
    ("push_lit @Object\n send class 0\n push_int 1\n send at: 1", "reading a class object"),
    ("push_lit @Object\n push_int 1\n push_nil\n send at:put: 2", "writing a class object"),
    ("push_int 7\n push_int 0\n send // 1", "division by zero"),
    ("push_int 7\n push_nil\n send \\\\ 1", "modulo by nil"),
    ("push_nil\n push_int 0\n send globalAt: 1", "global 0"),
    ("push_nil\n push_int 65\n send globalAt: 1", "global past the end"),
    ("push_lit @Array\n push_int 1\n send new: 1\n push_lit @Object\n send become: 1", "become: with a class"),
    ("push_int 1\n push_int 2\n send become: 1", "become: of SmallIntegers"),
] as [(String, String)])
func primitivesCheckTheirArguments(_ body: String, _ what: String) throws {
    // every primitive method gets a fallback body answering -1
    let fallbacks = """
    method Object at: temps=0 prim=1
      push_int -1
      return_top
    end
    method Object at:put: temps=0 prim=2
      push_int -1
      return_top
    end
    method Class new: temps=0 prim=3
      push_int -1
      return_top
    end
    method Object basicNew temps=0 prim=4
      push_int -1
      return_top
    end
    method Object class temps=0 prim=5
      push_int -1
      return_top
    end
    method SmallInteger // temps=0 prim=6
      push_int -1
      return_top
    end
    method SmallInteger \\\\ temps=0 prim=7
      push_int -1
      return_top
    end
    method Object become: temps=0 prim=8
      push_int -1
      return_top
    end
    method UndefinedObject globalAt: temps=0 prim=14
      push_int -1
      return_top
    end
    """
    let h = try Harness(fallbacks + runOf(" \(body)\n return_top"), base: [])
    defer { h.destroy() }
    #expect(try h.value() == -1, "\(what)")
    #expect(h.interpreter.counters.primitiveFailures == 1, "\(what)")
}

/// A primitive given the wrong number of arguments fails instead of reading
/// past them.
@Test func aPrimitiveChecksItsArgumentCount() throws {
    let h = try Harness("""
    method Object at temps=0 prim=1
      push_int -1
      return_top
    end
    method Object at:put:x: temps=0 prim=2
      push_int -2
      return_top
    end
    """ + runOf("""
      push_lit @Array
      push_int 2
      send new: 1
      store_temp 2
      push_temp 2
      send at 0
      push_temp 2
      push_int 1
      push_int 1
      push_int 1
      send at:put:x: 3
      add
      return_top
    """, temps: 1))
    defer { h.destroy() }
    #expect(try h.value() == -3)
}

/// An unimplemented primitive number always fails.
@Test func anUnknownPrimitiveFails() throws {
    let h = try Harness("method Object frob temps=0 prim=200\n push_int 5\n return_top\nend\n" + runOf(" push_nil\n send frob 0\n return_top"))
    defer { h.destroy() }
    #expect(try h.value() == 5)
}
