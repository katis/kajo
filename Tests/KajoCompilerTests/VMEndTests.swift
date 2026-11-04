// docs/modules/vm-teardown.md: after `shutdown` and `destroy` the image the
// host holds is whole. A VM with the default nursery configuration runs
// Smalltalk that leaves young objects reachable from a class-side instance
// variable, ends, and the host verifies the object memory, runs a second VM
// over the same image, saves it with `Image.saveImage` and loads the saved
// image, whose class still holds the objects with their contents. Under
// every young-collection mode, with 1 and 8 workers.

import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoVM

/// `Keep` holds, in its class-side `objs`, one Array per Process of `n`
/// three-slot Arrays (k, i, a one-slot Array holding i).
let vmEndFiles: [(file: String, text: [UInt8])] = miniKernel + [tonel("Keep", classIvars: ["objs"], """
    Keep class >> slots: n [
        objs := Array new: n.
        ^ 1
    ]
    Keep class >> fill: k count: n [
        | a |
        a := Array new: n.
        1 to: n do: [:i | | o b |
            b := Array new: 1.
            b at: 1 put: i.
            o := Array new: 3.
            o at: 1 put: k.
            o at: 2 put: i.
            o at: 3 put: b.
            a at: i put: o].
        objs at: k put: a.
        ^ 1
    ]
    Keep class >> total [
        | t |
        t := 0.
        1 to: objs size do: [:k | | a |
            a := objs at: k.
            1 to: a size do: [:i | | o |
                o := a at: i.
                t := t + (o at: 2) + ((o at: 3) at: 1)]].
        ^ t
    ]
    """)]

let vmEndImage: [UInt8] = {
    var o = KernelBuild.Options()
    o.initialize = false
    o.heapMiB = 64
    return try! KernelBuild.build(vmEndFiles, options: o).image
}()

/// The object memory configuration `kajo run` gives a VM of `workers`
/// background workers: the promotion reserve and the doubly mapped nursery
/// region, so the local and offload modes are what they say.
func vmEndMemory(workers: Int, heapMiB: Int = 64) -> ObjectMemoryConfig {
    let vc = VMConfig()
    var c = ObjectMemoryConfig()
    c.heapBytes = heapMiB << 20
    c.reserveBytes = vc.nursery.reserveBytes(workers: workers + 2)
    c.nurseryRegionBytes = vc.nursery.regionBytes(workers: workers + 2)
    return c
}

/// Run `Keep class >> selector` with `arguments` (SmallIntegers) as
/// `processes` Processes at once, the k-th getting k first when `indexed`.
/// The VM is ended (shutdown, destroy) and its end report answered.
@discardableResult
func runKeep(_ image: Image, mode: YoungMode, workers: Int, _ selector: String, _ arguments: [Int],
             processes: Int = 1, indexed: Bool = false) throws -> (answers: [Int64], end: VMEndReport) {
    var vc = VMConfig()
    vc.backgroundWorkers = workers
    vc.young.mode = mode
    let vm = VM(image: image, config: vc)
    #expect(vm.hasNursery)
    #expect(vm.youngMode == mode)
    vm.start()
    let cls = image.om.classOop(try #require(image.classIndex(named: "Keep")))
    var ps: [Oop] = []
    for k in 1...processes {
        let args = ((indexed ? [k] : []) + arguments).map { Oop(smallInteger: Int64($0)) }
        ps.append(try #require(vm.spawn(receiver: cls, selector: selector, arguments: args)))
    }
    vm.waitUntilAllTerminated()
    var answers: [Int64] = []
    for p in ps {
        if let e = vm.error(of: p) { throw RunError.vm("\(e)") }
        let v = vm.result(of: p)
        answers.append(v.isSmallInteger ? v.smallIntegerValue : -1)
        vm.release(p)
    }
    vm.shutdown()
    return (answers, vm.destroy())
}

@Suite(.serialized) struct VMEndTests {
    static let cases: [(YoungMode, Int)] = [(.stw, 1), (.stw, 8), (.local, 1), (.local, 8), (.offload, 1), (.offload, 8)]

    @Test(arguments: cases)
    func theImageIsWholeAfterTheVMEnds(_ mode: YoungMode, _ workers: Int) throws {
        let n = 300, processes = 8
        let image = try Image.load(image: vmEndImage, config: vmEndMemory(workers: workers))
        defer { image.destroy() }
        try runKeep(image, mode: mode, workers: workers, "slots:", [processes])
        let r = try runKeep(image, mode: mode, workers: workers, "fill:count:", [n], processes: processes, indexed: true)
        #expect(r.answers == Array(repeating: 1, count: processes))
        // The final collection promoted what the Processes left young
        // (nothing else collects 8 x 300 small Arrays in a 3 MiB eden).
        #expect(r.end.ran)
        #expect(r.end.promotedObjects >= UInt64(processes * n * 2))
        // The host holds a whole image: every verifier of module 1 passes.
        #expect(image.om.verifyHeap().isEmpty)
        #expect(image.om.verifyFreeLists().isEmpty)
        // A second VM over the same image reads what the first one made.
        let expected = Int64(processes * n * (n + 1))
        #expect(try runKeep(image, mode: mode, workers: workers, "total", []).answers == [expected])
        // The host saves it; the saved image loads (every loader rule),
        // verifies and runs, and the class still holds the objects.
        let saved = image.saveImage()
        let again = try Image.load(image: saved, config: vmEndMemory(workers: workers))
        defer { again.destroy() }
        let om = again.om
        let cls = om.classOop(try #require(again.classIndex(named: "Keep")))
        let objs = om.load(cls, Int(om.count(of: cls)) - 1)
        #expect(om.classIndex(of: objs) == WellKnown.array && om.count(of: objs) == UInt64(processes))
        for k in 0..<processes {
            let a = om.load(objs, k)
            #expect(om.count(of: a) == UInt64(n))
            for i in [0, n / 2, n - 1] {
                let o = om.load(a, i)
                #expect(om.load(o, 0) == Oop(smallInteger: Int64(k + 1)))
                #expect(om.load(o, 1) == Oop(smallInteger: Int64(i + 1)))
                #expect(om.load(om.load(o, 2), 0) == Oop(smallInteger: Int64(i + 1)))
            }
        }
        #expect(try runKeep(again, mode: mode, workers: workers, "total", []).answers == [expected])
    }

    /// The final collection's cost at the VM's end, reported (AGENTS.md:
    /// tests assert on work): a VM that ran nothing but one Process, and one
    /// whose nursery holds about 2.3 MB of live young objects (12 x 4000
    /// pairs of small Arrays; eden 3 MiB).
    @Test func theFinalCollectionsCostIsReported() throws {
        for (label, processes) in [("empty", 0), ("full", 12)] {
            let n = 4000
            let image = try Image.load(image: vmEndImage, config: vmEndMemory(workers: 1, heapMiB: 128))
            defer { image.destroy() }
            try runKeep(image, mode: .stw, workers: 1, "slots:", [max(processes, 1)])
            let r = processes == 0 ? try runKeep(image, mode: .stw, workers: 1, "slots:", [1])
                : try runKeep(image, mode: .stw, workers: 1, "fill:count:", [n], processes: processes, indexed: true)
            #expect(r.end.ran)
            if processes > 0 { #expect(r.end.promotedObjects >= UInt64(2 * n * processes)) }
            print("vm-end \(label): promoted \(r.end.promotedObjects) objects, \(r.end.promotedBytes) bytes; "
                  + "stop \(r.end.stopNs / 1000) us, work \(r.end.workNs / 1000) us")
            #expect(image.om.verifyHeap().isEmpty && image.om.verifyFreeLists().isEmpty)
        }
    }
}
