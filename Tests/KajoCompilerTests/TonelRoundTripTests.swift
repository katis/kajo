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
                  workers: Int = 1, strings: ((Oop) -> Void)? = nil) throws -> Oop {
    // The default configuration: the host may save the image afterwards
    // (docs/modules/vm-teardown.md: the image is whole when the VM ends).
    var vc = VMConfig()
    vc.backgroundWorkers = workers
    vc.sourcesDirectory = dir
    let vm = VM(image: image, config: vc)
    vm.start()
    defer { vm.terminateAll(); vm.waitUntilAllTerminated(); vm.shutdown(); vm.destroy() }
    let ci = try #require(image.classIndex(named: "Smalltalk"))
    let args = arguments.isEmpty ? [] : [vm.newStringArray(arguments)]
    let p = try #require(vm.spawn(receiver: image.om.classOop(ci), selector: selector, arguments: args))
    vm.waitUntilTerminated(p)
    if let e = vm.error(of: p) { throw RunError.vm("\(e)") }
    let v = vm.result(of: p)
    strings?(v)
    vm.release(p)
    return v
}

/// `Smalltalk selector: anArray` answering an Array of Strings.
func smalltalkStrings(_ image: Image, _ selector: String, _ arguments: [String]) throws -> [String] {
    var out: [String] = []
    _ = try runSmalltalk(image, selector, arguments) { a in
        let om = image.om
        guard a.isObject, om.classIndex(of: a) == WellKnown.array else { return }
        out = (0..<Int(om.count(of: a))).map { image.symbolName(om.load(a, $0)) ?? "<not a String>" }
    }
    return out
}

/// The bootstrap reader's fields of a Tonel file, as `TonelDocument>>summary`
/// writes the Smalltalk reader's.
func swiftSummary(_ t: TonelClass) -> String {
    let rs = "\u{1E}"
    var f = [t.name, t.superclass ?? "nil", t.instanceVariables.joined(separator: " "), t.classVariables.joined(separator: " "),
             t.classInstanceVariables.joined(separator: " "), t.category, t.type ?? "", t.comment, t.isExtension ? "extension" : "class"]
    for m in t.methods { f += [m.classSide ? "class" : "instance", m.category, String(decoding: m.source, as: UTF8.self)] }
    return f.joined(separator: rs)
}

let tonelFixtureDirectory: String = {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent()
    return url.appendingPathComponent("Fixtures/tonel").path
}()

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

    @Test func theTwoReadersReadEveryKernelFileAlike() throws {
        let image = try Image.load(image: kernelImage)
        defer { image.destroy() }
        let files = try KernelBuild.sources(in: [kernelDirectory, tonelFixtureDirectory])
        let texts = files.map { String(decoding: $0.text, as: UTF8.self) }
        let mine = try smalltalkStrings(image, "tonelSummaries:", texts)
        #expect(mine.count == files.count)
        var differing: [String] = []
        for (k, f) in files.enumerated() where k < mine.count {
            if try swiftSummary(readTonel(f.text, file: f.file)) != mine[k] { differing.append(f.file) }
        }
        #expect(differing.isEmpty, "\(differing.count) read differently: \(differing.prefix(5))")
    }

    @Test func aClassWrittenOutOfOneImageReadsBackIntoAnother() throws {
        // Image A: the kernel and the fixture, compiled by the bootstrap compiler.
        // (One VM per loaded image: each run loads the bytes afresh.)
        let bytesA = try KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, tonelFixtureDirectory])).image
        func onA(_ selector: String, _ args: [String]) throws -> [String] {
            let a = try Image.load(image: bytesA)
            defer { a.destroy() }
            return try smalltalkStrings(a, selector, args)
        }
        let written = try onA("tonelSourcesOf:", ["TonelFixture", "LiveSample", "ClassVariableSample"])
        let methodsA = try onA("methodListsOf:", ["TonelFixture"])
        #expect(written.count == 3 && methodsA.count == 1)
        // Image B: the kernel alone; TonelFixture read from A's text by the
        // reader and the compiler in Smalltalk. It writes out the same text
        // and its methods are A's, bytecode for bytecode.
        let b = try Image.load(image: kernelImage)
        defer { b.destroy() }
        #expect(!b.hasClass("TonelFixture"))
        let rewritten = try smalltalkStrings(b, "readTonelAll:", written)
        #expect(rewritten == written)
        // and its methods, saved and loaded with every check
        let saved = b.saveImage()
        let c = try Image.load(image: saved)
        defer { c.destroy() }
        let methodsB = try smalltalkStrings(c, "methodListsOf:", ["TonelFixture"])
        #expect(methodsB == methodsA)
    }
}
