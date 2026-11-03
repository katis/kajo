// The VM side of the one UTF-8 String (ADR 0009 section 8): byte
// comparison, hashing, concatenation, scalar decoding at boundaries,
// boundary checks, encoding into a buffer, interning, validation.

import Testing
@testable import KajoVM

/// "añ€😀": 1 + 2 + 3 + 4 bytes; offsets 1, 2, 4, 7 start scalars.
private let text = "'añ€😀'"

private func stringHarness(_ body: String, temps: Int = 0, switches: TestSwitches = TestSwitches()) throws -> Harness {
    try omHarness(runOf(body, temps: temps), switches: switches)
}

@Test func scalarsDecodeAtBoundariesOnly() throws {
    let h = try stringHarness(" push_lit \(text)\n push_temp 0\n send scalarAt: 1\n send value 0\n return_top")
    defer { h.destroy() }
    for (offset, scalar) in [(1, 0x61), (2, 0xF1), (4, 0x20AC), (7, 0x1F600)] {
        #expect(try h.value("run:of:", [Int64(offset), 0]) == Int64(scalar))
    }
    // inside a scalar, past the end, before the start: the primitive fails
    for offset: Int64 in [3, 5, 6, 8, 9, 10, 11, 0, -1] {
        #expect(h.error("run:of:", [offset, 0])?.kind == .primitiveFailed, "offset \(offset)")
    }
}

/// The rule: a position inside a scalar fails, never answers a broken
/// character. With the boundary check off (test switch) offset 3 answers
/// the continuation byte 0xB1 as a Character.
@Test(arguments: [false, true])
func aPositionInsideAScalarFails(_ broken: Bool) throws {
    var sw = TestSwitches()
    sw.noBoundaryCheck = broken
    let h = try stringHarness("""
      push_lit \(text)
      push_int 3
      send isBoundary: 1
      jump_if_true inside
      push_lit \(text)
      push_int 3
      send scalarAt: 1
      send value 0
      return_top
    inside:
      push_int -2
      return_top
    """, switches: sw)
    defer { h.destroy() }
    if broken {
        #expect(try h.value() == -2)
    } else {
        #expect(h.error()?.kind == .primitiveFailed)
    }
}

@Test func copyConcatenateCountAndSearch() throws {
    let h = try stringHarness("""
      push_lit \(text)
      push_int 2
      push_int 6
      send copyFrom:to: 2
      store_temp 2
      push_temp 2
      send scalarCount 0
      push_temp 2
      send byteSize 0
      push_int 10
      mul
      add
      push_lit 'ab'
      push_lit ' cd'
      send , 1
      send byteSize 0
      push_int 100
      mul
      add
      push_lit \(text)
      push_lit '€'
      push_int 1
      send indexOfSubstring:startingAt: 2
      push_lit 1000
      mul
      add
      return_top
    """, temps: 1)
    defer { h.destroy() }
    // "ñ€": 2 scalars, 5 bytes; "ab cd" 5 bytes; "€" at byte 4
    #expect(try h.value() == 2 + 50 + 500 + 4000)
    // copyFrom: 2 to: 4 ends inside "€": refused
    let bad = try stringHarness(" push_lit \(text)\n push_int 2\n push_int 4\n send copyFrom:to: 2\n return_top")
    defer { bad.destroy() }
    #expect(bad.error()?.kind == .primitiveFailed)
}

@Test func equalBytesHashAlikeAndInternToOneSymbol() throws {
    let h = try stringHarness("""
      push_lit 'hello'
      push_lit 'hel'
      push_lit 'lo'
      send , 1
      send sameBytesAs: 1
      jump_if_false bad
      push_lit 'hello'
      send hash 0
      push_lit #hello
      send hash 0
      eq
      jump_if_false bad
      push_lit 'hel'
      push_lit 'lo'
      send , 1
      send asSymbol 0
      push_lit #hello
      identical
      jump_if_false bad
      push_lit 'brandNew'
      send asSymbol 0
      push_lit 'brand'
      push_lit 'New'
      send , 1
      send asSymbol 0
      identical
      jump_if_false bad
      push_lit @Symbol
      push_lit 'neverSeen'
      send lookup: 1
      is_nil
      jump_if_false bad
      push_lit 'abc'
      push_lit 'abd'
      send compare: 1
      return_top
    bad:
      push_int 99
      return_top
    """)
    defer { h.destroy() }
    #expect(try h.value() == -1)
    #expect(h.interpreter.counters.symbolsInterned == 1)
    #expect(h.image.symbol("brandNew") != nil && h.om.isReadOnly(h.image.symbol("brandNew")!))
}

@Test func charactersEncodeIntoAByteBufferAndBytesValidate() throws {
    let h = try stringHarness("""
      push_lit @ByteArray
      push_int 8
      send new: 1
      store_temp 2
      push_temp 2
      push_lit $😀
      push_int 1
      send encode:at: 2
      push_temp 2
      push_lit $é
      push_int 5
      send encode:at: 2
      add
      push_temp 2
      send asStringRepairing 0
      push_int 1
      send scalarAt: 1
      send value 0
      push_lit 1000000
      mul
      add
      return_top
    """, temps: 1)
    defer { h.destroy() }
    // 4 + 2 bytes written; the buffer (with two trailing zero bytes) is
    // valid UTF-8 and decodes U+1F600 first
    #expect(try h.value() == 6 + 0x1F600 * 1_000_000)
    // no room: fails
    let full = try stringHarness(" push_lit @ByteArray\n push_int 3\n send new: 1\n push_lit $😀\n push_int 1\n send encode:at: 2\n return_top")
    defer { full.destroy() }
    #expect(full.error()?.kind == .primitiveFailed)
    #expect(isValidUTF8(Array("añ€😀".utf8)) && !isValidUTF8([0xC0, 0x80]) && !isValidUTF8([0xED, 0xA0, 0x80])
            && !isValidUTF8([0xF4, 0x90, 0x80, 0x80]) && !isValidUTF8([0xE2, 0x82]))
    #expect(repairedUTF8([0x61, 0xFF, 0x62]) == [0x61, 0xEF, 0xBF, 0xBD, 0x62])
}

@Test func invalidBytesAreRefusedUnlessRepaired() throws {
    let h = try stringHarness("""
      push_lit @ByteArray
      push_int 2
      send new: 1
      store_temp 2
      push_temp 2
      push_int 1
      push_lit 255
      send at:put: 2
      pop
      push_temp 2
      push_temp 0
      jump_if_true repair
      send asStringValidating 0
      return_top
    repair:
      send asStringRepairing 0
      send byteSize 0
      return_top
    """, temps: 1)
    defer { h.destroy() }
    #expect(h.run("run:of:", [0, 0]).isFailure)
    let bad = h.interpreter.run(on: h.stack, receiver: h.image.nilObject, selector: "run:of:",
                                arguments: [h.image.falseObject, Oop(smallInteger: 0)])
    if case .failure(let e) = bad { #expect(e.kind == .primitiveFailed) } else { Issue.record("validated invalid UTF-8") }
    let ok = h.interpreter.run(on: h.stack, receiver: h.image.nilObject, selector: "run:of:",
                               arguments: [h.image.trueObject, Oop(smallInteger: 0)])
    #expect(try ok.get() == Oop(smallInteger: 4))  // U+FFFD (3 bytes) and the NUL
}

@Test func thereIsNoAtPutOnAString() throws {
    let h = try stringHarness("""
      push_lit 'abc'
      send shallowCopy 0
      push_int 1
      push_int 65
      send at:put: 2
      return_top
    """)
    defer { h.destroy() }
    #expect(h.error()?.kind == .primitiveFailed)
}

extension Result {
    var isFailure: Bool { if case .failure = self { return true } else { return false } }
}
