// Module 8b: the weak symbol table (ADR 0009 section 8). A Symbol nothing
// references but the table is collected; its slot is a tombstone the next
// insertion into that bucket reuses; interning the same bytes again makes
// a fresh Symbol, and there is one live Symbol per spelling at any time.

import Testing
@testable import KajoVM

private let weakSymbolSrc = """
method UndefinedObject make temps=0
  push_lit 'zzWeakSymbol'
  send asSymbol 0
  pop
  return_self
end
method UndefinedObject same temps=0
  push_lit 'zzWeakSymbol'
  send asSymbol 0
  push_lit 'zzWeakSymbol'
  send asSymbol 0
  identical
  return_top
end
method UndefinedObject keep temps=0
  push_lit 'zzWeakSymbol'
  send asSymbol 0
  return_top
end
method UndefinedObject lookup temps=0
  push_lit @Symbol
  push_lit 'zzWeakSymbol'
  send lookup: 1
  return_top
end
"""

@Test func anUnreferencedSymbolIsCollectedAndItsSlotReused() throws {
    let h = try omHarness(weakSymbolSrc)
    defer { h.destroy() }
    let om = h.om, table = h.image.symbolTable
    let bytes = Array("zzWeakSymbol".utf8)
    _ = try h.run("make").get()
    let first = om.symbolLookupSlot(table, hash: utf8Hash(bytes)) { om.sameBytes($0, bytes) }
    #expect(first.symbol != .none)
    let before = om.symbolCount(table)
    om.collect()
    #expect(h.image.symbol("zzWeakSymbol") == nil)
    #expect(om.symbolCount(table) == before - 1)
    #expect(om.load(first.bucket, first.slot) == h.image.nilObject)  // the tombstone
    #expect(try h.run("lookup").get() == h.image.nilObject)
    // Interned again: a fresh Symbol in the tombstone's slot, one per spelling.
    #expect(try h.run("same").get() == h.image.trueObject)
    let again = om.symbolLookupSlot(table, hash: utf8Hash(bytes)) { om.sameBytes($0, bytes) }
    #expect(again.symbol != .none && again.bucket == first.bucket && again.slot == first.slot)
    #expect(om.symbolCount(table) == before)
}

@Test func aReferencedSymbolSurvives() throws {
    let h = try omHarness(weakSymbolSrc)
    defer { h.destroy() }
    let sym = try h.run("keep").get()
    om_collect(h, keeping: sym)
    #expect(h.image.symbol("zzWeakSymbol") == sym)
    #expect(try h.run("lookup").get() == sym)
    #expect(try h.run("same").get() == h.image.trueObject)
}

private func om_collect(_ h: Harness, keeping o: Oop) {
    let r = h.om.addRoot(o)
    h.om.collect()
    h.om.removeRoot(r)
}

@Test func theWeakTableSurvivesImageRoundTrips() throws {
    let h = try omHarness(weakSymbolSrc)
    defer { h.destroy() }
    _ = try h.run("make").get()
    h.om.collect()  // leaves a tombstone
    let count = h.om.symbolCount(h.image.symbolTable)
    let bytes = h.image.saveImage()
    let loaded = try Image.load(image: bytes)
    defer { loaded.destroy() }
    #expect(loaded.om.symbolCount(loaded.symbolTable) == count)
    #expect(loaded.symbol("zzWeakSymbol") == nil)
    #expect(loaded.symbol("doesNotUnderstand:") != nil)
    // and through a second round trip, with the Symbol interned again
    let again = try Image.load(image: loaded.saveImage())
    defer { again.destroy() }
    #expect(again.om.symbolCount(again.symbolTable) == count)
}
