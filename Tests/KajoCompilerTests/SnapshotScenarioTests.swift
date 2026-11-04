// Module 8c in Smalltalk: the kernel's Mutex, Monitor, SharedQueue, Delay,
// ensure:, on:do:, non-local return and finalization Process saved in the
// image mid-run (`Tests/KajoCompilerTests/Fixtures/snapshot/`), resumed in a
// fresh VM, answering what the run that saved answered.

import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoVM

let scenarioDirectory: String = {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent()
    return url.appendingPathComponent("Fixtures/snapshot").path
}()

/// The kernel and the scenarios, built once.
let scenarioImage: [UInt8] = {
    try! KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, scenarioDirectory])).image
}()

func scenarioVM(_ bytes: [UInt8], workers: Int) throws -> (Image, VM) {
    var o = Headless.Options()
    o.heapMiB = 256
    o.workers = workers
    let (vc, c) = try Headless.configs(o).get()
    var oc = c
    oc.onVerifyFailure = .record
    let img = try Image.load(image: bytes, config: oc)
    let vm = VM(image: img, config: vc)
    vm.start()
    return (img, vm)
}

func endVM(_ img: Image, _ vm: VM) {
    vm.terminateAll()
    vm.waitUntilAllTerminated()
    vm.shutdown()
    #expect(img.om.counters.verifierFailures == 0)
    vm.destroy()
    img.destroy()
}

/// Run `SnapshotScenarios selector` to its end: its answer, its id, and the
/// images it saved.
func runScenario(_ bytes: [UInt8], _ selector: String, _ args: [Oop] = [], workers: Int = 2)
    throws -> (answer: Int64?, id: Int64, images: [[UInt8]]) {
    let (img, vm) = try scenarioVM(bytes, workers: workers)
    let cls = img.om.classOop(img.classIndex(named: "SnapshotScenarios")!)
    let p = try #require(vm.spawn(receiver: cls, selector: selector, arguments: args))
    let id = vm.inspect { $0.load(p, ProcessLayout.id).smallIntegerValue }
    vm.waitUntilTerminated(p)
    if let e = vm.error(of: p) { Issue.record("\(selector): \(e)") }
    let v = vm.result(of: p)
    let images = vm.takeSavedImages()
    endVM(img, vm)
    return (v.isSmallInteger ? v.smallIntegerValue : nil, id, images)
}

/// Resume an image and let the Process `id` run to its end.
func resumeScenario(_ bytes: [UInt8], id: Int64, workers: Int = 3) throws -> (answer: Int64?, images: [[UInt8]]) {
    let (img, vm) = try scenarioVM(bytes, workers: workers)
    let p = try #require(vm.resumedProcesses.first { q in vm.inspect { $0.load(q, ProcessLayout.id).smallIntegerValue } == id })
    #expect(vm.resumedSaver == p)
    vm.waitUntilTerminated(p)
    if let e = vm.error(of: p) { Issue.record("resumed \(id): \(e)") }
    let v = vm.result(of: p)
    let images = vm.takeSavedImages()
    endVM(img, vm)
    return (v.isSmallInteger ? v.smallIntegerValue : nil, images)
}

@Suite(.serialized) struct SnapshotScenarioTests {
    @Test(arguments: [("mutex", 91), ("monitor", 3), ("sharedQueue", 3825), ("delay", 7), ("unwinding", 1111),
                      ("finalization", 3), ("removedMethod", 1), ("redefinedClass", 39)])
    func aScenarioResumesWithTheSameAnswer(_ selector: String, _ expected: Int64) throws {
        let run = try runScenario(scenarioImage, selector)
        #expect(run.answer == expected)
        #expect(run.images.count == 1)
        guard let image = run.images.first else { return }
        // A different worker count where it resumes.
        let resumed = try resumeScenario(image, id: run.id)
        #expect(resumed.answer == expected, "\(selector) resumed")
    }

    @Test func savingTwiceAndSavingAResumedImage() throws {
        let run = try runScenario(scenarioImage, "twice")
        #expect(run.answer == 1 && run.images.count == 2)
        guard run.images.count == 2 else { return }
        let fromFirst = try resumeScenario(run.images[0], id: run.id)
        #expect(fromFirst.answer == 10 && fromFirst.images.count == 1)
        let fromSecond = try resumeScenario(run.images[1], id: run.id, workers: 1)
        #expect(fromSecond.answer == 101)
        if let again = fromFirst.images.first {
            let fromResumed = try resumeScenario(again, id: run.id)
            #expect(fromResumed.answer == 110)
        }
    }

    @Test func kajoTestRefusesAnImageWithSavedProcessesAndRunResumesIt() throws {
        let run = try runScenario(scenarioImage, "monitor")
        guard let image = run.images.first else { Issue.record("no image"); return }
        let (r, _) = runKernelTests(image)
        guard case .failure(let f) = r else { Issue.record("kajo test ran an image with saved Processes"); return }
        #expect("\(f)".contains("saved Processes"))
        var o = Headless.Options()
        o.heapMiB = 256
        o.workers = 2
        let outcome = Headless.run(image: image, options: o)
        // Every resumed Process that answered: the scenario (3) and the two
        // Processes that waited on the Monitor (their blocks answer the
        // done Semaphore's signal, not an integer); the finalization
        // Process waits on, and the run ends quiescent.
        #expect(try outcome.checksum.get() >= 3)
    }

    /// The images built from kernel/ still start at their entry point.
    @Test func anImageWithoutProcessesStartsAtTheEntryPoint() throws {
        var o = Headless.Options()
        o.heapMiB = 256
        let outcome = Headless.run(image: scenarioImage, options: o)
        #expect(try outcome.checksum.get() == 0)
    }
}

/// Module 8c's measurements (`KAJO_MEASURE_SNAPSHOT=1`, release build): the
/// save's stop with a few hundred Processes in the kernel image, the
/// image's size with and without them, the load and the resume.
@Test func measureTheSave() throws {
    guard ProcessInfo.processInfo.environment["KAJO_MEASURE_SNAPSHOT"] != nil else { return }
    func ms(_ ns: UInt64) -> String { String(format: "%.2f", Double(ns) / 1e6) }
    for n in [0, 300] {
        var pauses: [UInt64] = [], works: [UInt64] = [], loads: [UInt64] = [], installs: [UInt64] = [], sizes: [Int] = []
        for _ in 0..<5 {
            let (img, vm) = try scenarioVM(scenarioImage, workers: 4)
            let cls = img.om.classOop(img.classIndex(named: "SnapshotScenarios")!)
            let p = try #require(vm.spawn(receiver: cls, selector: "manyProcesses:", arguments: [Oop(smallInteger: Int64(n))]))
            vm.waitUntilTerminated(p)
            let work = vm.counters[.snapshotNs]
            let stop = vm.stops.filter { $0.pauseNs >= work }.map(\.pauseNs).max() ?? 0
            let bytes = try #require(vm.takeSavedImages().first)
            endVM(img, vm)
            var o = Headless.Options()
            o.heapMiB = 256
            let (vc, c) = try Headless.configs(o).get()
            let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let loaded = try Image.load(image: bytes, config: c)
            let t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let vm2 = VM(image: loaded, config: vc)
            let t2 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            vm2.destroy()
            loaded.destroy()
            pauses.append(stop); works.append(work); loads.append(t1 - t0); installs.append(t2 - t1); sizes.append(bytes.count)
        }
        func med(_ xs: [UInt64]) -> String { ms(xs.sorted()[xs.count / 2]) }
        print("SNAPSHOT n=\(n) processes: stop ms \(med(pauses)) (\(pauses.map(ms))), save work ms \(med(works)), image bytes \(sizes), load ms \(med(loads)) (\(loads.map(ms))), VM with install ms \(med(installs)); kernel image \(scenarioImage.count) bytes")
    }
    let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    var o = Headless.Options()
    o.heapMiB = 256
    let (_, c) = try Headless.configs(o).get()
    for _ in 0..<5 { try Image.load(image: scenarioImage, config: c).destroy() }
    print("SNAPSHOT plain kernel image load ms \(ms((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 5))")
}
