// Module 8e: the contract between the image and the files. The image built
// from kernel/ writes every class out (the Tonel writer in Smalltalk,
// through the file primitives) and every file is byte for byte the one it
// was built from; the reader in Smalltalk and the bootstrap reader in Swift
// read every kernel file alike; a class written out and read back into the
// image is the same class with the same methods.

import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoVM

/// Spawn `Smalltalk selector` (with one Array of Strings as its argument
/// when `arguments` is not empty) on the kernel image
/// in a VM whose file primitives are opened on `dir`; its answer.
func runSmalltalk(_ image: Image, _ selector: String, _ arguments: [String] = [], sources dir: String? = nil,
                  workers: Int = 1) throws -> Oop {
    var o = Headless.Options()
    o.heapMiB = 256
    o.workers = workers
    o.sourcesDirectory = dir
    let (vc, _) = try Headless.configs(o).get()
    let vm = VM(image: image, config: vc)
    vm.start()
    defer { vm.terminateAll(); vm.waitUntilAllTerminated(); vm.shutdown(); vm.destroy() }
    let ci = try #require(image.classIndex(named: "Smalltalk"))
    let args = arguments.isEmpty ? [] : [vm.newStringArray(arguments)]
    let p = try #require(vm.spawn(receiver: image.om.classOop(ci), selector: selector, arguments: args))
    vm.waitUntilTerminated(p)
    if let e = vm.error(of: p) { throw RunError.vm("\(e)") }
    let v = vm.result(of: p)
    vm.release(p)
    return v
}

func temporaryDirectory(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kajo-\(name)-\(getpid())")
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite(.serialized) struct TonelRoundTripTests {
    @Test func theKernelWrittenOutIsTheKernelByteForByte() throws {
        let image = try Image.load(image: kernelImage)
        defer { image.destroy() }
        let dir = try temporaryDirectory("tonel")
        defer { if ProcessInfo.processInfo.environment["KAJO_KEEP_TONEL"] == nil { try? FileManager.default.removeItem(at: dir) } }
        let n = try runSmalltalk(image, "writeAllTonel", sources: dir.path)
        let kernelFiles = try FileManager.default.contentsOfDirectory(atPath: kernelDirectory).filter { $0.hasSuffix(".st") }.sorted()
        let written = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(n == Oop(smallInteger: Int64(kernelFiles.count)))
        #expect(written == kernelFiles)
        var differing: [String] = []
        for f in kernelFiles {
            let a = FileManager.default.contents(atPath: kernelDirectory + "/" + f)
            let b = FileManager.default.contents(atPath: dir.path + "/" + f)
            if a != b { differing.append(f) }
        }
        #expect(differing.isEmpty, "\(differing.count) files differ: \(differing.prefix(10))")
    }
}
