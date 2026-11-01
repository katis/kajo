// One test file for every variant (symlinked into VMATests, VMBTests,
// VMCTests). Variant-specific expectations are under #if.

import Testing
import Kasm
#if VARIANT_A
@testable import VMA
#elseif VARIANT_B
@testable import VMB
#else
@testable import VMC
#endif

private let prelude = try! readTextFile("\(oldKernelsDir)/prelude.kasm")
private let lib = try! readTextFile("\(newKernelsDir)/lib.kasm")

private func image(_ src: String, heap: Int = 64 << 20) throws -> Image {
    try Image.fromSources([prelude, lib, src], heapSize: heap)
}

/// Run `run:of:` on one worker; answer its result.
private func run(_ img: Image, _ sel: String = "run:of:") -> Int64 {
    runKernel(img, workers: 1, selector: sel).checksum
}

/// The object a reference denotes, whatever the representation.
private func deref(_ om: OM, _ v: Oop) -> Oop {
    #if FORWARDERS
    follow(om, v)
    #else
    v
    #endif
}

/// Stop the (worker-less) world from the host and run an operation.
private func op(_ img: Image, _ o: SafeOp) {
    stopWorld(img.vm, img.boot, o, retry: true)
}

private func newObj(_ img: Image, _ cls: String, _ vals: [Int64]) throws -> Oop {
    let o = alloc(img.vm, img.boot, try img.classIndex(cls), vals.count, false)
    for (i, v) in vals.enumerated() { img.vm.pointee.om.setSlot(o, i, mkInt(v)) }
    return o
}

private func array(_ img: Image, _ elems: [Oop]) -> Oop {
    let a = alloc(img.vm, img.boot, ciArray, elems.count, false)
    for (i, e) in elems.enumerated() { img.vm.pointee.om.setSlot(a, i, e) }
    return a
}

// MARK: - encoding

@Test func headerPackingAndSizes() {
    let h = makeHeader(7, 3, true) | markBit
    #expect(hdrClass(h) == 7 && hdrSlots(h) == 3 && hdrIsBytes(h) && hdrMarked(h))
    #expect(objectBytes(makeHeader(1, 2, false)) == 24)
    #expect(objectBytes(makeHeader(1, 9, true)) == 24)
}

@Test func oopsAreTaggedAndNonZero() throws {
    let img = try image("")
    let vm = img.vm
    #expect(vm.pointee.nilObj != 0 && vm.pointee.nilObj & 1 == 0)
    #if OOP_OFFSET
    #expect(vm.pointee.nilObj == 8) // first object, biased offset
    #elseif VARIANT_B
    #expect(vm.pointee.nilObj & 15 == 0 && vm.pointee.nilObj < UInt64(tableEntries * 16))
    #else
    #expect(UInt(vm.pointee.nilObj) == vm.pointee.heap.baseAddr)
    #endif
}

@Test func kernelsAssemble() throws {
    for k in allKernels {
        for src in try kernelSources(k) { for m in try parseKasm(src).methods { _ = try assemble(m) } }
    }
}

// MARK: - interpreter sanity

@Test func smallProgramRuns() throws {
    let src = "method UndefinedObject run:of: temps=0\n push_int 20\n send fibx 0\n push_temp 0\n add\n return_top\nend\n"
    #expect(run(try image(src)) == 6765)
}

// MARK: - GC

@Test func gcKeepsSurvivorsAndReclaimsGarbage() throws {
    let img = try image("class N Object 2\n", heap: 32 * blockSize * 4)
    let vm = img.vm, om = vm.pointee.om
    let w = Worker.create(id: 0, nilObj: vm.pointee.nilObj)
    setWorkers(vm, [w])
    w.pointee.sp += 1
    var head = vm.pointee.nilObj
    for i in 0..<1000 {
        w.pointee.sp.pointee = head
        let n = alloc(vm, w, try img.classIndex("N"), 2, false)
        om.setSlot(n, 0, head)
        om.setSlot(n, 1, mkInt(Int64(i)))
        head = n
    }
    w.pointee.sp.pointee = head
    for _ in 0..<200_000 { _ = alloc(vm, w, ciArray, 20, false) }
    #expect(vm.metric(.gcCount) > 3)
    var p = w.pointee.sp.pointee
    var i: Int64 = 999
    while p != vm.pointee.nilObj {
        #expect(intVal(om.slot(p, 1)) == i)
        #expect(!hdrMarked(om.header(p)))
        i -= 1
        p = om.slot(p, 0)
    }
    #expect(i == -1)
    #if VARIANT_B
    #expect(w.pointee.ws.refills > 3) // entries came back through the pool
    #endif
}

// MARK: - become

@Test func twoWayBecomeSwapsIdentities() throws {
    let img = try image("class P Object 2\nclass Q Object 3\n")
    let vm = img.vm, om = vm.pointee.om
    let a = try newObj(img, "P", [1, 2])
    let b = try newObj(img, "Q", [7, 8, 9])
    let holder = array(img, [a, b, a])
    vm.pointee.globals[0] = holder
    op(img, .become(a, b))
    let x = deref(om, om.slot(holder, 0)), y = deref(om, om.slot(holder, 1))
    #expect(om.classIndexOf(x) == UInt64(try img.classIndex("Q")))
    #expect(intVal(om.slot(x, 2)) == 9)
    #expect(om.classIndexOf(y) == UInt64(try img.classIndex("P")))
    #expect(intVal(om.slot(y, 0)) == 1)
    #expect(deref(om, om.slot(holder, 2)) == x)
    #if FORWARDERS
    #expect(isForwarder(om, om.slot(holder, 0)))
    #expect(vm.metric(.becomeFwdPath) == 1)
    op(img, .gc(0))
    // the GC rewrote the slots to the targets and freed the forwarders
    #expect(!isForwarder(om, om.slot(holder, 0)) && !isForwarder(om, om.slot(holder, 2)))
    #expect(om.slot(holder, 0) == x && om.slot(holder, 1) == y)
    #else
    #expect(om.slot(holder, 0) == a) // the identity stayed; the entry changed
    #endif
}

#if FORWARDERS
@Test func sameSizeBecomeSwapsInPlace() throws {
    let img = try image("class P Object 2\n")
    let om = img.vm.pointee.om
    let a = try newObj(img, "P", [1, 2]), b = try newObj(img, "P", [3, 4])
    img.vm.pointee.globals[0] = array(img, [a, b])
    op(img, .become(a, b))
    #expect(!isForwarder(om, a) && intVal(om.slot(a, 0)) == 3 && intVal(om.slot(b, 0)) == 1)
    #expect(img.vm.metric(.becomeSwapPath) == 1)
}

@Test func forwarderChainsAreFollowed() throws {
    let img = try image("class P Object 2\n")
    let om = img.vm.pointee.om
    let a = try newObj(img, "P", [1, 1]), b = try newObj(img, "P", [2, 2]), c = try newObj(img, "P", [3, 3])
    makeForwarder(om, a, b)
    makeForwarder(om, b, c)
    #expect(follow(om, a) == c)
    #expect(maybeForwardedIdentical(om, a, c))
    #expect(!maybeForwardedIdentical(om, a, try newObj(img, "P", [4, 4])))
}
#endif

/// The interpreter sees a two-way become: sends through the forwarded
/// receiver, `==` through forwarders, temps patched on the stack.
@Test func interpreterSeesBecome() throws {
    let src = """
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
    """
    #expect(run(try image(src)) == 120)
}

@Test func bulkForwardRedirectsEveryReference() throws {
    let img = try image("class P Object 2\n")
    let vm = img.vm, om = vm.pointee.om
    var froms: [Oop] = [], tos: [Oop] = []
    for i in 0..<10 { froms.append(try newObj(img, "P", [Int64(i), 0])); tos.append(try newObj(img, "P", [Int64(100 + i), 0])) }
    let holder = array(img, froms + tos)
    vm.pointee.globals[0] = holder
    let fa = array(img, [array(img, froms)]), ta = array(img, [array(img, tos)])
    vm.pointee.globals[1] = fa
    vm.pointee.globals[2] = ta
    op(img, .forward(fa, ta))
    for i in 0..<10 {
        #expect(deref(om, om.slot(holder, i)) == deref(om, om.slot(holder, 10 + i)))
        #expect(intVal(om.slot(deref(om, om.slot(holder, i)), 0)) == Int64(100 + i))
    }
    #expect(vm.metric(.forwardPairs) == 10)
}

// MARK: - reshape

@Test func reshapeAddsAnInstanceVariable() throws {
    let img = try image("class R Object 2\n")
    let vm = img.vm, om = vm.pointee.om
    let objs = try (0..<50).map { try newObj(img, "R", [Int64($0), Int64(2 * $0)]) }
    let holder = array(img, objs)
    vm.pointee.globals[0] = holder
    let cls = classAt(vm, UInt64(try img.classIndex("R")))
    op(img, .reshape(cls))
    #expect(intVal(om.slot(cls, cInstSize)) == 3)
    #expect(vm.metric(.reshapeCount) == 50)
    for i in 0..<50 {
        let o = deref(om, om.slot(holder, i))
        #expect(hdrSlots(om.header(o)) == 3)
        #expect(intVal(om.slot(o, 1)) == Int64(2 * i))
        #expect(om.slot(o, 2) == vm.pointee.nilObj)
    }
    op(img, .gc(0))
    #if FORWARDERS
    for i in 0..<50 { #expect(!isForwarder(om, om.slot(holder, i))) }
    #else
    #expect(om.slot(holder, 7) == objs[7]) // same oop, new body
    #endif
}

// MARK: - compaction

/// Garbage before the program's methods, then a compaction from deep inside
/// a recursion: methods, bytecodes and frames' saved pcs all move.
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
    let img = Image(heapSize: 64 << 20)
    for _ in 0..<5000 { _ = alloc(img.vm, img.boot, ciArray, 10, false) } // garbage below the methods
    try img.load([prelude, lib, src].map(parseKasm))
    retireBoot(img.vm, img.boot)
    let before = img.symbol("down:list:")!
    #expect(run(img) == 499500 + 1275)
    #expect(img.vm.metric(.compactObjectsMoved) > 1000)
    #expect(img.vm.metric(.compactPcsFixed) >= 52)
    #if !VARIANT_B
    #expect(img.symbol("down:list:")! != before) // symbols moved (roots updated)
    #else
    #expect(img.symbol("down:list:")! == before) // oops never change in B
    #endif
    #expect(run(img) == 499500 + 1275) // and the moved image still runs
}

// MARK: - snapshot

@Test func snapshotRoundTripAtANewBase() throws {
    let src = """
    method UndefinedObject run:of: temps=0
      push_nil
      push_int 1
      push_nil
      push_lit 4096
      send buildGraph: 1
      send globalAt:put: 2
      pop
      push_nil
      push_int 2
      push_lit 4096
      send globalAt:put: 2
      pop
      push_nil
      send snapshot 0
      pop
      push_nil
      push_nil
      push_int 1
      send globalAt: 1
      push_int 0
      send get: 1
      push_lit 4096
      send walk:hops: 2
      return_top
    end
    method UndefinedObject again:of: temps=0
      push_nil
      push_nil
      push_int 1
      send globalAt: 1
      push_int 0
      send get: 1
      push_lit 4096
      send walk:hops: 2
      return_top
    end
    """
    let img = try image(src)
    let path = "\(newKernelsDir)/../swift/.build/test-snapshot-\(variantName).img"
    img.vm.pointee.snapshotPath = path
    let before = run(img)
    let loaded = try loadSnapshot(path)
    #expect(loaded.vm.pointee.heap.baseAddr != img.vm.pointee.heap.baseAddr)
    #expect(run(loaded, "again:of:") == before)
    let changed = countChangedWords(loaded.vm, path)
    #if FORWARDERS && !OOP_OFFSET
    #expect(loaded.vm.metric(.snapRelocSlots) > 8192)
    #expect(UInt64(changed) == loaded.vm.metric(.snapRelocSlots))
    #else
    #expect(loaded.vm.metric(.snapRelocSlots) == 0)
    #expect(changed == 0)
    #endif
}

// MARK: - stop-the-world operations with busy workers (run under TSan too)

@Test func operationsWhileOtherWorkersRun() throws {
    let src = """
    class R Object 2
    class P Object 2
    class Q Object 3
    method R a temps=0
      push_ivar 0
      return_top
    end
    method R setA: temps=0
      push_temp 0
      store_ivar 0
      return_self
    end
    method UndefinedObject spin temps=0
    loop:
      push_nil
      send stopRequested 0
      jump_if_true done
      push_int 12
      send fibx 0
      pop
      jump loop
    done:
      push_int 0
      return_top
    end
    ; worker 0: 2000 R's (with garbage between), become, reshape, gc, compact
    method UndefinedObject main temps=4
      push_nil
      push_lit 2000
      send bigNew: 1
      store_temp 0
      push_int 0
      store_temp 1
    fill:
      push_temp 1
      push_lit 2000
      lt
      jump_if_false filled
      push_lit @Array
      push_int 3
      send new: 1
      pop
      push_temp 0
      push_lit @R
      send basicNew 0
      push_temp 1
      send setA: 1
      push_temp 1
      send put:at: 2
      pop
      push_temp 1
      push_int 1
      add
      store_temp 1
      jump fill
    filled:
      push_lit @P
      send basicNew 0
      push_lit @Q
      send basicNew 0
      send become: 1
      pop
      push_lit @R
      send addInstVar 0
      pop
      push_nil
      push_int 1
      send gc: 1
      pop
      push_nil
      push_int 4
      send compact: 1
      pop
      push_int 0
      store_temp 2
      push_int 0
      store_temp 1
    sum:
      push_temp 1
      push_lit 2000
      lt
      jump_if_false done
      push_temp 2
      push_temp 0
      push_temp 1
      send get: 1
      send a 0
      add
      store_temp 2
      push_temp 1
      push_int 1
      add
      store_temp 1
      jump sum
    done:
      push_temp 2
      return_top
    end
    method UndefinedObject t:of: temps=0
      push_temp 0
      push_int 0
      eq
      jump_if_false other
      push_nil
      send main 0
      push_nil
      send stopOthers 0
      pop
      return_top
    other:
      push_nil
      send spin 0
      return_top
    end
    """
    let img = try image(src)
    let r = runKernel(img, workers: 4, selector: "t:of:")
    #expect(r.checksum == 1999 * 2000 / 2)
    #expect(img.vm.metric(.stwCount) >= 4)
}
