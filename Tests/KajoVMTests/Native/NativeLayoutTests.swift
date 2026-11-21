import Foundation
import Testing
import KajoAOT
@testable import KajoVM

// The third review's small fixes, part 2, item 1 (interpreter.A2): the
// layout hash covers every layout fact the generated code relies on. The
// barrier word's place in the flag line is a constant of the layout (its
// value the VM's own `barrierWordIndex`), so moving it changes the hash and
// a module built before the move is refused at bind; the frame's indices
// are emitted from `Frame`, and the three C structs are asserted against
// their Swift mirrors in the tables file.

/// The constant is the distance the VM itself uses, and a change of it
/// changes the hash (the seam: the same hash over a changed list).
@Test func theLayoutHashCoversTheBarrierWordsPlace() throws {
    let c = NativeLayout.constants
    let i = try #require(c.firstIndex { $0.name == "FLAG_BARRIER_WORD" })
    let flag = makeFlagLine()
    defer { freeFlagLine(flag) }
    #expect(c[i].value == UInt64(barrierWord(flag) - flag), "the constant is not barrierWord's own distance")
    #expect(NativeLayout.hash(of: c) == NativeLayout.hash)
    var moved = c
    moved[i].value += 1
    #expect(NativeLayout.hash(of: moved) != NativeLayout.hash)
}

/// The generated store tests the word through the constant, not a digit,
/// and the tables file asserts the three structs' mirrors.
@Test func theGeneratedCodeNamesTheBarrierWordAndAssertsTheMirrors() throws {
    let files = [("prelude.kasm", kernel("prelude")), ("lib.kasm", kernel("lib")), ("storeheavy.kasm", kernel("storeheavy"))]
    let image = try Image(memory: ObjectMemory(ObjectMemoryConfig()))
    defer { image.destroy() }
    try image.load(files.map { (file: $0.0, text: $0.1) })
    let out = NativeTest.source(for: image)
    let all = out.source + out.files.map(\.text).joined(separator: "\n")
    #expect(all.contains("AT(s, W_FLAG, u32 *) + FLAG_BARRIER_WORD"))
    #expect(!all.contains("AT(s, W_FLAG, u32 *) + 2"))
    for s in ["KResume", "KGroup", "KModule"] {
        #expect(all.contains("_Static_assert(sizeof(\(s)) == "), "no size assert for \(s)")
    }
    #expect(all.contains("_Static_assert(__builtin_offsetof(KModule, declined) == \(ModuleOffset.declined)"))
}
