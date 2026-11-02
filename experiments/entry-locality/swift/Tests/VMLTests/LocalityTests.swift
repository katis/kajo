// L-only tests (SPEC.md "Variant L layout").

import Testing
import Kasm
@testable import VML

private let prelude = try! readTextFile("\(oldKernelsDir)/prelude.kasm")
private let lib = try! readTextFile("\(newKernelsDir)/lib.kasm")

private func image(_ src: String, heap: Int = 64 << 20) throws -> Image {
    try Image.fromSources([prelude, lib, src], heapSize: heap)
}

@inline(__always) private func page(_ a: UInt) -> UInt { a / 16384 }

@Test func entryAndBodyShareAPageAtAllocation() throws {
    let img = try image("class N Object 2\n")
    let vm = img.vm
    let w = Worker.create(id: 0, nilObj: vm.pointee.nilObj)
    setWorkers(vm, [w])
    var shared = 0
    for i in 0..<20_000 {
        let n = alloc(vm, w, try img.classIndex("N"), i % 7, i % 3 == 0)
        let (e, b) = entryAndBody(vm, n)
        #expect(page(e) == page(b))
        if page(e) == page(b) { shared += 1 }
        #expect(e % 16384 >= b % 16384) // entry above its body in the block
    }
    #expect(shared == 20_000)
}

@Test func largeBodiesLiveInTheLargeArenaWithASmallEntry() throws {
    let img = try image("")
    let vm = img.vm
    let w = Worker.create(id: 0, nilObj: vm.pointee.nilObj)
    setWorkers(vm, [w])
    let a = alloc(vm, w, ciArray, 2048, false)
    let (e, b) = entryAndBody(vm, a)
    #expect(vm.pointee.heap.small.contains(e))
    #expect(vm.pointee.heap.large.contains(b))
    #expect(vm.pointee.om.slot(a, 2047) == vm.pointee.nilObj)
}

@Test func fullBlockMeetsInTheMiddle() throws {
    let img = try image("class N Object 2\n")
    let vm = img.vm
    let w = Worker.create(id: 0, nilObj: vm.pointee.nilObj)
    setWorkers(vm, [w])
    let first = alloc(vm, w, try img.classIndex("N"), 2, false)
    let block = page(entryAndBody(vm, first).0)
    var count = 1
    while true {
        let n = alloc(vm, w, try img.classIndex("N"), 2, false)
        if page(entryAndBody(vm, n).0) != block { break }
        count += 1
    }
    // 24-byte bodies + 16-byte entries: 409 objects in a fresh 16 KiB block
    #expect(count <= 16384 / 40 && count >= 16384 / 40 - 1)
}

@Test func compactionKeepsEntriesAndMovesBodiesAway() throws {
    let src = """
    class N Object 2
    method UndefinedObject run:of: temps=0
      push_nil
      push_int 1
      push_nil
      push_lit 8192
      send buildGraph: 1
      send globalAt:put: 2
      pop
      push_nil
      push_int 4
      send compact: 1
      pop
      push_nil
      push_nil
      push_int 1
      send globalAt: 1
      push_int 0
      send get: 1
      push_lit 8192
      send walk:hops: 2
      return_top
    end
    """
    let img = try image(src)
    let r = runKernel(img, workers: 1).checksum
    let img2 = try image(src.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.contains("compact:") ? "  send gc: 1" : String($0) }.joined(separator: "\n"))
    #expect(r == runKernel(img2, workers: 1).checksum)
    #expect(localityLine(img.vm).contains("entries_used="))
}
