import Testing
@testable import KajoVM

private let makesAP = """
class P Object 1
method UndefinedObject make temps=0
  push_lit @P
  send basicNew 0
  return_top
end
"""

/// From concurrent-young's lesson (SPEC amendment 8, AGENTS.md): the
/// `result` register is a root while it holds a value nobody has taken,
/// and only then. A stale result kept dead objects alive and hid a lost
/// object; this test fails without clearing it.
@Test func theResultRegisterIsARootOnlyWhileLive() throws {
    let h = try Harness(makesAP, base: ["prelude"])
    defer { h.destroy() }
    let p = try h.interpreter.runToReturn(on: h.stack, receiver: h.image.nilObject, selector: "make", arguments: []).get()
    #expect(h.om.classIndex(of: p) == h.image.classIndex(named: "P"))
    h.interpreter.collect(h.stack)                   // live: the register keeps it
    #expect(h.om.isUsedReference(p) && h.om.classIndex(of: p) == h.image.classIndex(named: "P"))
    #expect(h.interpreter.takeResult() == p)
    h.interpreter.collect(h.stack)                   // taken: nothing keeps it
    #expect(!h.om.isUsedReference(p))
}

/// Every register that holds an oop is handed to the collector: a
/// collection in the middle of a method (a primitive) keeps the receiver,
/// temps and operand stack, and the run finishes with the right objects.
@Test func aCollectionInsideAMethodKeepsItsFrames() throws {
    let h = try Harness("""
    class Node Object 2
    method Node v temps=0
      push_ivar 0
      return_top
    end
    method Node v:next: temps=0
      push_temp 0
      store_ivar 0
      push_temp 1
      store_ivar 1
      return_self
    end
    method Node sumAfterGC temps=0
      push_nil
      push_int 0
      send gc: 1
      pop
      push_ivar 0
      push_ivar 1
      send v 0
      add
      return_top
    end
    """ + runOf("""
      push_lit @Node
      send basicNew 0
      push_int 40
      push_lit @Node
      send basicNew 0
      push_int 2
      push_nil
      send v:next: 2
      send v:next: 2
      send sumAfterGC 0
      return_top
    """))
    defer { h.destroy() }
    let before = h.om.counters.collections
    #expect(try h.value() == 42)
    #expect(h.om.counters.collections == before + 1)
    #expect(h.interpreter.counters.collectionsTriggered == 1)
}

/// Ported from object-representation, the live-frames half: garbage below
/// the methods, then a compaction from 50 frames deep. Methods, bytecodes
/// and literal frames move while frames run in them; the interpreter
/// re-derives its two cached bases after the primitive and the frames'
/// saved pcs are offsets, so nothing in the stack needs fixing.
@Test func compactionMovesMethodsUnderLiveFrames() throws {
    let src = """
    class N Object 2
    method N v temps=0
      push_ivar 0
      return_top
    end
    method N next temps=0
      push_ivar 1
      return_top
    end
    method N setV:next: temps=0
      push_temp 0
      store_ivar 0
      push_temp 1
      store_ivar 1
      return_self
    end
    ; nil down: k list: l -> compacts at depth 0, then sums the list
    method UndefinedObject down:list: temps=0
      push_temp 0
      push_int 0
      eq
      jump_if_false rec
      push_nil
      push_int 4
      send compact: 1
      pop
      push_nil
      push_temp 1
      send sum: 1
      return_top
    rec:
      push_nil
      push_temp 0
      push_int 1
      sub
      push_temp 1
      send down:list: 2
      push_temp 0
      add
      return_top
    end
    method UndefinedObject sum: temps=1
      push_int 0
      store_temp 1
    loop:
      push_temp 0
      push_nil
      identical
      jump_if_true done
      push_temp 1
      push_temp 0
      send v 0
      add
      store_temp 1
      push_temp 0
      send next 0
      store_temp 0
      jump loop
    done:
      push_temp 1
      return_top
    end
    ; build a list of 1000 with garbage in between, then recurse 50 deep
    method UndefinedObject run:of: temps=3
      push_int 0
      store_temp 2
    loop:
      push_temp 2
      push_lit 1000
      lt
      jump_if_false go
      push_lit @Array
      push_int 5
      send new: 1
      pop
      push_lit @N
      send basicNew 0
      push_temp 2
      push_temp 3
      send setV:next: 2
      store_temp 3
      push_temp 2
      push_int 1
      add
      store_temp 2
      jump loop
    go:
      push_nil
      push_int 50
      push_temp 3
      send down:list: 2
      return_top
    end
    """
    // Module 6 pins methods for good; this test is module 2's re-derivation
    // after a stop-the-world compaction, so its image pins nothing.
    let h = try Harness(src, pinsForGood: false) { img in
        for _ in 0..<5000 { _ = img.om.allocate(img.context, classIndex: WellKnown.array, slots: 10, fill: img.nilObject) }
    }
    defer { h.destroy() }
    let down = try #require(h.image.lookup(WellKnown.undefinedObject, h.image.symbol("down:list:")!))
    let code = h.om.load(down, MethodLayout.bytecodes)
    let codeBefore = h.om.bodyOffset(code), litsBefore = h.om.bodyOffset(h.om.load(down, MethodLayout.literals))
    let symbolBefore = h.image.symbol("down:list:")
    #expect(try h.value() == 499_500 + 1275)
    #expect(h.om.counters.compactions == 1 && h.om.counters.objectsMoved > 1000)
    #expect(h.om.bodyOffset(code) != codeBefore)                       // the running method's bytecodes moved
    #expect(h.om.bodyOffset(h.om.load(down, MethodLayout.literals)) != litsBefore)
    #expect(h.image.symbol("down:list:") == symbolBefore)              // oops never change
    #expect(try h.value() == 499_500 + 1275)                           // and the moved image still runs
    #expect(verified(h.om) == [])
}

/// Ported from object-representation: the interpreter sees a two-way
/// become through a send, through `==`, and through a temp.
@Test func interpreterSeesBecome() throws {
    let h = try Harness("""
    class P Object 2
    class Q Object 3
    method P tag temps=0
      push_int 1
      return_top
    end
    method Q tag temps=0
      push_int 2
      return_top
    end
    ; t2 a, t3 b, t4 arr
    method UndefinedObject run:of: temps=3
      push_lit @P
      send basicNew 0
      store_temp 2
      push_lit @Q
      send basicNew 0
      store_temp 3
      push_lit @Array
      push_int 1
      send new: 1
      store_temp 4
      push_temp 4
      push_int 1
      push_temp 2
      send at:put: 2
      pop
      push_temp 2
      push_temp 3
      send become: 1
      pop
      push_temp 4
      push_int 1
      send at: 1
      send tag 0
      push_int 10
      mul
      push_temp 4
      push_int 1
      send at: 1
      push_temp 2
      identical
      jump_if_false no
      push_int 100
      add
    no:
      return_top
    end
    """)
    defer { h.destroy() }
    #expect(try h.value() == 120)
}

/// The lookup cache holds oops, so it is flushed at every collection; a
/// collection with a populated cache, then sends through it, must work,
/// and the misses after it show the flush happened.
@Test func theLookupCacheIsFlushedAtEveryCollection() throws {
    let src = """
    method UndefinedObject work temps=0
      push_int 10
      send fibx 0
      return_top
    end
    method UndefinedObject plain temps=0
      push_nil
      send work 0
      push_nil
      push_int 0
      send identity: 1
      pop
      push_nil
      send work 0
      add
      return_top
    end
    method UndefinedObject withGC temps=0
      push_nil
      send work 0
      push_nil
      push_int 0
      send gc: 1
      pop
      push_nil
      send work 0
      add
      return_top
    end
    method UndefinedObject identity: temps=0
      push_self
      return_top
    end
    """
    let a = try Harness(src), b = try Harness(src)
    defer { a.destroy(); b.destroy() }
    #expect(try a.value("plain", []) == 110)
    #expect(try b.value("withGC", []) == 110)
    // plain misses run once each for plain, work, fibx, identity:; withGC
    // misses work and fibx again after the flush
    #expect(a.interpreter.counters.cacheMisses == 4)
    #expect(b.interpreter.counters.cacheMisses == 6)
    #expect(b.interpreter.counters.cacheFlushes == 1)
}

/// A load can override an inherited method; the cache entry that found the
/// inherited one must not survive it.
@Test func aLoadFlushesTheLookupCache() throws {
    let h = try Harness("""
    class A Object 0
    class B A 0
    method A tag temps=0
      push_int 1
      return_top
    end
    method UndefinedObject probe temps=0
      push_lit @B
      send basicNew 0
      send tag 0
      return_top
    end
    """)
    defer { h.destroy() }
    #expect(try h.value("probe", []) == 1)
    try h.image.load([(file: "b.kasm", text: "method B tag temps=0\n push_int 2\n return_top\nend\n")])
    #expect(try h.value("probe", []) == 2)
}

/// The safepoint poll at sends and backward jumps is one load of a flag
/// the interpreter is given. In this module the flag is a test switch that
/// makes every poll collect.
@Test func aRequestedSafepointCollectsAtEveryPoll() throws {
    let h = try Harness(runOf("""
      push_int 0
      store_temp 2
    loop:
      push_temp 2
      push_int 50
      lt
      jump_if_false done
      push_lit @Array
      push_int 3
      send new: 1
      pop
      push_temp 2
      push_int 1
      add
      store_temp 2
      jump loop
    done:
      push_int 12
      send fibx 0
      return_top
    """, temps: 1))
    defer { h.destroy() }
    #expect(try h.value() == 144)
    #expect(h.interpreter.counters.safepointPolls == 0)
    h.interpreter.safepointRequested = true
    #expect(try h.value() == 144)
    let c = h.interpreter.counters
    // 50 sends of new: and 50 backward jumps, 465 sends of fibx
    #expect(c.safepointPolls == 50 + 50 + 465)
    #expect(c.collectionsTriggered == c.safepointPolls)
    #expect(verified(h.om) == [])
}
