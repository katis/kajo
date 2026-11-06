// The image format: module 1's snapshot plus a verified method table; the
// loader checks the object model's rules and every method before anything
// runs, all or nothing.

import Foundation
import Testing
@testable import KajoVM

private let imageSrc = """
class Acc Object 1
method Acc add: temps=0
  push_ivar 0
  is_nil
  jump_if_false has
  push_int 0
  store_ivar 0
has:
  push_ivar 0
  push_temp 0
  add
  store_ivar 0
  return_self
end
method Acc total temps=0
  push_ivar 0
  return_top
end
; sum 1..n through a closure over a temp vector, plus 'añ' scalarCount
method UndefinedObject run:of: temps=2
  push_new_array 1
  store_temp 2
  push_int 0
  store_tv_slot 0 2
  push_int 1
  store_temp 3
loop:
  push_temp 3
  push_temp 0
  le
  jump_if_false done
  push_temp 2
  push_closure body 1
  push_temp 3
  value1
  pop
  push_temp 3
  push_int 1
  add
  store_temp 3
  jump loop
done:
  push_tv_slot 0 2
  push_lit 'añ'
  send scalarCount 0
  add
  return_top
block body args=1 copied=1 temps=0
  push_tv_slot 0 1
  push_temp 0
  add
  store_tv_slot 0 1
  push_nil
  block_return
end
"""

private func builtImage() throws -> Image {
    let img = try makeImage()
    try img.load(["prelude", "objectmodel"].map { (file: "\($0).kasm", text: kernel($0)) } + [(file: "t.kasm", text: imageSrc)])
    return img
}

private func imageConfig() -> ObjectMemoryConfig {
    var c = ObjectMemoryConfig()
    c.heapBytes = 256 * BlockHeap.blockBytes
    c.entryCapacity = 1 << 18
    c.verify = true
    c.onVerifyFailure = .trap
    return c
}

private func run(_ img: Image, _ n: Int64) throws -> Int64 {
    let i = Interpreter(image: img)
    let st = Stack(words: 1 << 14)
    defer { st.destroy(); i.destroy() }
    let v = try i.run(on: st, receiver: img.nilObject, selector: "run:of:", arguments: [Oop(smallInteger: n), Oop(smallInteger: 1)]).get()
    return v.smallIntegerValue
}

@Test func anImageRoundTripsAndRunsAfterVerification() throws {
    let img = try builtImage()
    #expect(try run(img, 100) == 5050 + 2)
    let bytes = try img.saveImage()
    img.destroy()
    let loaded = try Image.load(image: bytes, config: imageConfig())
    defer { loaded.destroy() }
    #expect(try run(loaded, 100) == 5050 + 2)
    #expect(loaded.classIndex(named: "Acc") != nil && loaded.symbol("total") != nil)
    // the restored image loads more kasm on top
    try loaded.load([(file: "more.kasm", text: "method Acc twice temps=0\n push_ivar 0\n push_int 2\n mul\n return_top\nend\n")])
    #expect(loaded.lookup(loaded.classIndex(named: "Acc")!, loaded.symbol("twice")!) != nil)
}

private enum Corruption: String, CaseIterable {
    case badMagic, badVersion, aVersion2Image, aVersion4Image, aVersion5Image, unknownFlags, truncated, methodMissingFromTable, extraTableEntry
    case badOpcode, jumpIntoAnOperand, maxStackTooSmall, literalNotASelector, ivarOutsideTheClass, methodOfAnotherClass
    case methodNotPinned, liveContext, aProcess, closureOfTheWrongSize, badClassFormatForInstance
    case misplacedSymbol, specialSelectorChanged, wellKnownClassRenamed, dictionaryOfAnotherClass, methodClassCycle
}

private func corrupt(_ c: Corruption) throws -> [UInt8] {
    let img = try builtImage()
    defer { img.destroy() }
    let om = img.om
    let acc = img.classIndex(named: "Acc")!
    let add = img.lookup(acc, img.symbol("add:")!)!
    let total = img.lookup(acc, img.symbol("total")!)!
    let addBytes = om.load(add, MethodLayout.bytecodes)
    switch c {
    case .badOpcode: om.storeByte(addBytes, 0, 0xEE)
    case .jumpIntoAnOperand:
        // jump_if_false has: offset 2 -> 3 (into push_int's operand)
        let b = om.bytes(of: addBytes)
        let at = b.firstIndex(of: Opcode.jumpIfFalse.rawValue)!
        om.storeByte(addBytes, at + 1, b[at + 1] + 1)
    case .maxStackTooSmall: om.store(add, MethodLayout.maxStack, Oop(smallInteger: 0))
    case .literalNotASelector:
        let run = img.lookup(WellKnown.undefinedObject, img.symbol("run:of:")!)!
        let lits = om.load(run, MethodLayout.literals)
        for i in 0..<Int(om.count(of: lits)) where om.load(lits, i) == img.symbol("scalarCount")! {
            om.store(lits, i, Oop(smallInteger: 3))
        }
    case .ivarOutsideTheClass:
        om.setClassFormat(acc, ClassFormat(namedSlots: 0, kind: .fixed))
        om.store(om.classOop(acc), ClassLayout.instSize, Oop(smallInteger: 0))
    case .methodOfAnotherClass: om.store(add, MethodLayout.methodClass, om.classOop(WellKnown.object))
    case .methodNotPinned: om.setHeader(total, Header(raw: om.headerWord(total.raw) & ~Header.pinnedForGoodBit))
    case .liveContext:
        let ctx = om.allocate(img.context, classIndex: WellKnown.context, slots: ContextLayout.size, fill: img.nilObject,
                              extraRoots: [])!
        om.store(ctx, ContextLayout.frame, Oop(smallInteger: 12))
        om.addRoot(ctx)
    case .aProcess:
        om.addRoot(om.allocate(img.context, classIndex: WellKnown.process, slots: ProcessLayout.size, fill: img.nilObject,
                               extraRoots: [])!)
    case .closureOfTheWrongSize:
        let run = img.lookup(WellKnown.undefinedObject, img.symbol("run:of:")!)!
        let block = om.load(om.load(run, MethodLayout.literals), 0)
        let cl = om.allocate(img.context, classIndex: WellKnown.blockClosure, slots: ClosureLayout.size, fill: img.nilObject,
                             extraRoots: [])!
        om.store(cl, ClosureLayout.method, block)  // copies 1 value, holds none
        om.addRoot(cl)
    case .badClassFormatForInstance:
        om.addRoot(om.allocateBytes(img.context, classIndex: acc, count: 3, extraRoots: [])!)
    case .misplacedSymbol:
        let t = img.symbolTable
        for j in 0..<SymbolTable.buckets where om.load(t, j) != img.nilObject {
            om.store(t, (j + 1) % SymbolTable.buckets, om.load(t, j))
            om.store(t, j, img.nilObject)
            break
        }
    case .specialSelectorChanged:
        om.store(om.load(img.specialObjects, SpecialObjects.selectors), 0, img.symbol("total")!)
    case .wellKnownClassRenamed: om.store(om.classOop(WellKnown.string), ClassLayout.name, img.symbol("total")!)
    case .dictionaryOfAnotherClass:
        om.store(om.classOop(WellKnown.trueClass), ClassLayout.methodDict, om.load(om.classOop(acc), ClassLayout.methodDict))
    case .methodClassCycle:
        om.store(om.classOop(acc), ClassLayout.superclass, om.classOop(acc))
    default: break
    }
    // Module 10: the host's save refuses a live Process; the loader's own
    // refusal is what this case tests, so it encodes the image itself.
    var b = c == .aProcess ? img.encodedImage(snapshot: om.snapshot()) : try img.saveImage()
    func put(_ i: Int, _ v: UInt64) { for k in 0..<8 { b[8 * i + k] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(k))) } }
    switch c {
    case .badMagic: b[0] ^= 1
    case .badVersion: put(1, 7)
    // module 8d: 8c's images (version 2) are refused, their Metaclass objects a slot short
    case .aVersion2Image: put(1, 2)
    case .aVersion4Image: put(1, 4)  // module 9b's, before module 10's runs
    case .aVersion5Image: put(1, 5)  // module 10's, before the long byte objects
    case .unknownFlags: put(5, 2)
    case .truncated: b.removeLast(9)
    case .methodMissingFromTable:
        // drop the first table entry and shrink the count
        let m = Int(b[24]) | Int(b[25]) << 8
        let t = 8 * ImageFile.headerWords
        b.removeSubrange(t..<(t + 8))
        put(3, UInt64(m - 1))
    case .extraTableEntry:
        let m = Int(b[24]) | Int(b[25]) << 8
        let t = 8 * ImageFile.headerWords
        b.insert(contentsOf: Array(b[t..<(t + 8)]), at: t)
        put(3, UInt64(m + 1))
    default: break
    }
    return b
}

@Test(arguments: Corruption.allCases)
private func theImageLoaderRejects(_ c: Corruption) throws {
    let b = try corrupt(c)
    do {
        try Image.load(image: b, config: imageConfig()).destroy()
        Issue.record("\(c.rawValue) loaded")
    } catch {
        print("image corruption \(c.rawValue): \(error)")
    }
}

/// Seeded mutations of a valid image: each loads cleanly (and passes every
/// verifier) or is refused; nothing traps.
@Test func mutatedImagesLoadCleanOrAreRejected() throws {
    let seed = try { let i = try builtImage(); defer { i.destroy() }; return try i.saveImage() }()
    // The snapshot fuzzer's image seed (`Fixtures/fuzz/snapshot/image.img`);
    // `KAJO_WRITE_FUZZ_SEEDS=1` writes it (module 8d: version 3).
    if ProcessInfo.processInfo.environment["KAJO_WRITE_FUZZ_SEEDS"] != nil {
        try Data(seed).write(to: URL(fileURLWithPath: "\(fixturesDir)/fuzz/snapshot/image.img"))
    }
    var g = SplitMix(seed: 11)
    var loaded = 0, rejected = 0
    for _ in 0..<300 {
        var b = seed
        for _ in 0..<(1 + Int(g.next() % 3)) {
            let k = Int(g.next() % UInt64(b.count))
            b[k] ^= UInt8(truncatingIfNeeded: 1 << (g.next() % 8))
        }
        if FuzzEntry.image(b) { loaded += 1 } else { rejected += 1 }
    }
    #expect(rejected > 0 && loaded + rejected == 300)
}

/// Module 10: an image with large objects (runs of blocks) round-trips,
/// and seeded mutations of it load cleanly or are refused. The snapshot
/// fuzzer's run seed (`Fixtures/fuzz/snapshot/large-objects.img`);
/// `KAJO_WRITE_FUZZ_SEEDS=1` writes it.
@Test func mutatedImagesWithRunsLoadCleanOrAreRejected() throws {
    let seed = try {
        let i = try builtImage()
        defer { i.destroy() }
        let ctx = i.om.makeContext()
        defer { i.om.destroyContext(ctx) }
        let a = i.om.tryAllocateAny(ctx, classIndex: WellKnown.array, count: 9_000, isBytes: false, fill: i.nilObject)
        let b = i.om.tryAllocateAny(ctx, classIndex: WellKnown.byteArray, count: 40_000, isBytes: true, fill: i.nilObject)
        #expect(a != .none && b != .none)
        i.om.store(a, 8_999, b)
        i.om.store(a, 0, Oop(smallInteger: 7))
        i.om.storeByte(b, 39_999, 5)
        i.om.store(i.globals, Image.globalCount - 1, a)
        return try i.saveImage()
    }()
    let back = try Image.load(image: seed, config: imageConfig())
    let a = back.om.load(back.globals, Image.globalCount - 1)
    #expect(back.om.count(of: a) == 9_000 && back.om.load(a, 0) == Oop(smallInteger: 7))
    #expect(back.om.loadByte(back.om.load(a, 8_999), 39_999) == 5)
    #expect(back.om.heap.kind(back.om.blockIndex(of: a)) == BlockKind.head)
    back.destroy()
    if ProcessInfo.processInfo.environment["KAJO_WRITE_FUZZ_SEEDS"] != nil {
        try Data(seed).write(to: URL(fileURLWithPath: "\(fixturesDir)/fuzz/snapshot/large-objects.img"))
    }
    #expect(FuzzEntry.image(seed))
    // Half the flips land in the snapshot's block table, where the kinds are.
    let methods = (0..<8).reduce(0) { $0 | Int(seed[24 + $1]) << (8 * $1) }
    let snapAt = 8 * (ImageFile.headerWords + methods)
    let L = try SnapshotLayout(parsing: Array(seed[snapAt...]))
    var g = SplitMix(seed: 12)
    var loaded = 0, rejected = 0
    for _ in 0..<300 {
        var b = seed
        for _ in 0..<(1 + Int(g.next() % 3)) {
            let k = g.next() % 2 == 0 ? snapAt + L.usedAt + Int(g.next() % UInt64(8 * L.blockCount)) : Int(g.next() % UInt64(b.count))
            b[k] ^= UInt8(truncatingIfNeeded: 1 << (g.next() % 8))
        }
        if FuzzEntry.image(b) { loaded += 1 } else { rejected += 1 }
    }
    #expect(rejected > 0 && loaded + rejected == 300)
}

/// Regressions found by `just fuzz snapshot`: each loads cleanly or is
/// refused, never traps.
@Test(arguments: ["crash-wellknown-name", "crash-marker-offset", "crash-nil-not-root"])
func fuzzFoundInputsNeverTrap(_ name: String) throws {
    // crash-wellknown-name: a Character where a well-known class's name
    // Symbol was (one bit): the loader read its bytes as an object's
    // (signal 11 in release). crash-marker-offset: a snapshot whose entry
    // 52 has bit 48 set in its state word (one bit): the heap verifier
    // passed it and the marker read the body at that offset (signal 11).
    // crash-nil-not-root (module 8b's run): a snapshot naming a nil object
    // that no root holds; the collection after loading swept it and the
    // verifier trapped ("the nil object (a root) is @3"). The loader now
    // refuses it.
    let url = URL(fileURLWithPath: "\(fixturesDir)/fuzz/snapshot/\(name).img")
    let b = [UInt8](try Data(contentsOf: url))
    #expect(!FuzzEntry.snapshotOrImage(b))
}
