import Testing
@testable import KajoVM

let kernelsDir = String(#filePath.split(separator: "/", omittingEmptySubsequences: false).dropLast(4).joined(separator: "/")) + "/kernels"

// MARK: tagging and header packing

@Test func smallIntRoundTrip() {
    for i: Int64 in [0, 1, -1, 42, -42, intMax, intMin] {
        let v = mkInt(i)
        #expect(isInt(v))
        #expect(intVal(v) == i)
    }
    #expect(!fitsInt(intMax + 1))
    #expect(!fitsInt(intMin - 1))
}

@Test func taggedOrderingIsMonotonic() {
    #expect(Int64(bitPattern: mkInt(-5)) < Int64(bitPattern: mkInt(3)))
    #expect(Int64(bitPattern: mkInt(intMin)) < Int64(bitPattern: mkInt(intMax)))
}

@Test func headerPacking() {
    var h = makeHeader(0x3F_FFFF, 0xFFFF_FFFF, false)
    #expect(hdrClass(h) == 0x3F_FFFF)
    #expect(hdrSlots(h) == 0xFFFF_FFFF)
    #expect(!hdrMarked(h) && !hdrIsBytes(h))
    h = makeHeader(7, 3, true) | markBit
    #expect(hdrClass(h) == 7)
    #expect(hdrSlots(h) == 3)
    #expect(hdrIsBytes(h) && hdrMarked(h))
    #expect(h == 7 | (3 << 22) | (1 << 54) | (1 << 55))
}

@Test func objectSizes() {
    #expect(objectBytes(makeHeader(1, 0, false)) == 8)
    #expect(objectBytes(makeHeader(1, 2, false)) == 24)
    #expect(objectBytes(makeHeader(1, 1, true)) == 16)
    #expect(objectBytes(makeHeader(1, 8, true)) == 16)
    #expect(objectBytes(makeHeader(1, 9, true)) == 24)
}

// MARK: assembler

@Test func argcOfSelectors() {
    #expect(selectorArgc("fib") == 0)
    #expect(selectorArgc("at:put:") == 2)
    #expect(selectorArgc("+") == 1)
    #expect(selectorArgc("\\\\") == 1)
    #expect(selectorArgc("run:of:") == 2)
}

@Test func parsesClassesAndMethods() throws {
    let p = try parseKasm("class Foo Object 2 ; c\nmethod Foo bar: temps=1 \n push_temp 0\n return_top\nend\nmethod Object at: temps=0 prim=1\nend\n")
    #expect(p.classes == [ClassDef(name: "Foo", superclass: "Object", instSize: 2)])
    #expect(p.methods.count == 2)
    #expect(p.methods[0].temps == 1)
    #expect(p.methods[1].prim == 1)
    #expect(p.methods[1].code.isEmpty)
}

@Test func assemblesJumpsLiteralsAndSends() throws {
    let p = try parseKasm("method Object m temps=0\nloop:\n push_lit 1000\n push_lit #foo\n push_lit 1000\n send at:put: 2\n jump_if_false loop\n push_int -1\n jump loop\nend\n")
    let a = try assemble(p.methods[0])
    #expect(a.literals == [.int(1000), .sym("foo"), .sym("at:put:")])
    #expect(a.bytecodes == [1, 0, 1, 1, 1, 0, 0x0C, 2, 2, 0x11, 0xF4, 0xFF, 0x0B, 0xFF, 0x0F, 0xEF, 0xFF])
    #expect(a.maxStack == 3)
    #expect(a.argc == 0)
}

@Test func rejectsArgcMismatchAndUnknownOps() {
    #expect(throws: KasmError.self) { try parseKasm("method Object m temps=0\n send at: 2\nend\n") }
    #expect(throws: KasmError.self) { try parseKasm("method Object m temps=0\n frob\nend\n") }
}

@Test func kernelsAssemble() throws {
    for k in ["prelude", "arith", "fib", "sends", "alloc"] {
        let src = try kernelSources(dir: kernelsDir, kernel: k)[1]
        for m in try parseKasm(src).methods { _ = try assemble(m) }
    }
}

// MARK: lookup

@Test func lookupWalksSuperclassChain() throws {
    let img = try Image.fromSources(["class A Object 0\nclass B A 1\nmethod A foo temps=0\n push_int 1\n return_top\nend\nmethod B bar temps=0\n return_self\nend\nmethod A bar temps=0\n return_self\nend\n"])
    let vm = img.vm
    let a = UInt64(try img.classIndex("A")), b = UInt64(try img.classIndex("B"))
    #expect(a == UInt64(firstUserClass))
    let foo = img.symbols["foo"]!, bar = img.symbols["bar"]!
    let aFoo = lookup(vm, a, foo)
    #expect(aFoo != 0)
    #expect(lookup(vm, b, foo) == aFoo)
    let bBar = lookup(vm, b, bar)
    #expect(bBar != lookup(vm, a, bar))
    #expect(slot(bBar, mSelector) == bar)
    #expect(lookup(vm, UInt64(ciSmallInt), foo) == 0)
    #expect(intVal(slot(classAt(vm, b), cInstSize)) == 1)
}

// MARK: GC

@Test func gcReclaimsGarbageAndKeepsSurvivors() {
    // 1 MiB heap = 32 blocks; allocate ~40 MiB total with a live list.
    let vm = VMCore.create(heapSize: 32 * blockSize)
    let boot = Worker.create(id: 0, nilObj: 0)
    vm.pointee.nilObj = alloc(vm, boot, ciNil, 0, false)
    vm.pointee.roots.push(vm.pointee.nilObj)
    vm.pointee.heap.retire(&boot.pointee.tlab)
    let w = Worker.create(id: 0, nilObj: vm.pointee.nilObj)
    setWorkers(vm, [w])
    var head = vm.pointee.nilObj
    w.pointee.sp += 1
    for i in 0..<1000 {
        w.pointee.sp.pointee = head
        let node = alloc(vm, w, ciArray, 2, false)
        setSlot(node, 0, head)
        setSlot(node, 1, mkInt(Int64(i)))
        head = node
    }
    w.pointee.sp.pointee = head
    for i in 0..<200_000 {
        let g = alloc(vm, w, ciArray, 20, i % 3 == 0)
        #expect(hdrSlots(header(g)) == 20)
    }
    #expect(vm.pointee.gcCount > 5)
    var p = w.pointee.sp.pointee
    var i: Int64 = 999
    while p != vm.pointee.nilObj {
        #expect(hdrClass(header(p)) == UInt64(ciArray))
        #expect(!hdrMarked(header(p)))
        #expect(intVal(slot(p, 1)) == i)
        i -= 1
        p = slot(p, 0)
    }
    #expect(i == -1)
}

// MARK: interpreter

private func runSrc(_ src: String, _ n: Int) throws -> RunResult {
    let prelude = try kernelSources(dir: kernelsDir, kernel: "prelude")[0]
    return runKernel(try Image.fromSources([prelude, src]), workers: n)
}

@Test func smallProgramsRun() throws {
    let src = "method SmallInteger fib temps=0\n push_self\n push_int 2\n lt\n jump_if_false r\n push_self\n return_top\nr:\n push_self\n push_int 1\n sub\n send fib 0\n push_self\n push_int 2\n sub\n send fib 0\n add\n return_top\nend\nmethod UndefinedObject run:of: temps=0\n push_int 20\n send fib 0\n push_temp 0\n add\n return_top\nend\n"
    #expect(try runSrc(src, 1).checksum == 6765)
    #expect(try runSrc(src, 4).results == [6765, 6766, 6767, 6768])
}

@Test func primitivesAndDivision() throws {
    let src = "class P Object 1\nmethod UndefinedObject run:of: temps=1\n push_lit @Array\n push_int 3\n send new: 1\n store_temp 2\n push_temp 2\n push_int 2\n push_int -7\n push_int 2\n send // 1\n send at:put: 2\n pop\n push_temp 2\n push_int 2\n send at: 1\n push_int -7\n push_int 2\n send \\\\ 1\n add\n push_lit @P\n send basicNew 0\n send class 0\n push_lit @P\n identical\n jump_if_false bad\n return_top\nbad:\n push_int 99\n return_top\nend\n"
    #expect(try runSrc(src, 1).checksum == -3)
}
