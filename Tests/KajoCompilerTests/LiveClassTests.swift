// Module 8e: classes from Smalltalk at the VM's level: the define,
// redefine and remove primitives on a small image (no kernel), the image
// saved and loaded with every rule of the loader after the change, the
// snapshot fuzzer's seed with such a class; the file primitives' directory
// rule; the stop's length for a class of 10 000 instances and 50 methods.

import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoVM

/// Run `className selector` (class side) in a one-worker VM over `image`
/// and answer the SmallInteger it answered.
func answerOf(_ image: Image, _ className: String, _ selector: String, sources: String? = nil) throws -> Int64 {
    var vc = VMConfig()
    vc.backgroundWorkers = 1
    vc.nursery.bytes = 0
    vc.marking.enabled = false
    vc.relocation.enabled = false
    vc.young.mode = .stw
    vc.sourcesDirectory = sources
    let vm = VM(image: image, config: vc)
    vm.start()
    defer { vm.shutdown(); vm.destroy() }
    guard let ci = image.classIndex(named: className),
          let p = vm.spawn(receiver: image.om.classOop(ci), selector: selector) else { throw RunError.noMethod }
    vm.waitUntilAllTerminated()
    if let e = vm.error(of: p) { throw RunError.vm("\(e)") }
    let v = vm.result(of: p)
    vm.release(p)
    guard v.isSmallInteger else { throw RunError.notAnInteger("\(v)") }
    return v.smallIntegerValue
}

/// The primitives driven directly, with the specifications ClassBuilder
/// would send: a class Point3 (x y, a class variable Origin) defined,
/// three instances, reshaped to (z y x), its class side given an instance
/// variable, its pool replaced, a second class defined and removed; each
/// step answers 1, a refusal -1.
let objectExtras: (file: String, text: [UInt8]) = ("ObjectExtras.st", Array("""
    Extension { #name : #Object }

    Object >> instVarAt: i put: v [ <primitive: 92> ^ nil ]
    """.utf8))

let liveClassFiles: [(file: String, text: [UInt8])] = miniKernel + [objectExtras,
    tonel("Binding", ivars: ["key", "value"], ""),
    tonel("T", classIvars: ["cls", "objs", "gone"], """
    T class >> redefine: spec [
        <primitive: 146>
        ^ nil
    ]
    T class >> remove: c as: n [
        <primitive: 147>
        ^ nil
    ]
    T class >> step1 [
        | r |
        r := self primDefine: {#Point3. Object. #(#x #y). #(). #(#Origin). #fixed. Binding. 0. 0}.
        r class == String ifTrue: [^ -1].
        cls := r.
        objs := Array new: 3.
        1 to: 3 do: [:i | | o | o := cls basicNew. o instVarAt: 1 put: i. o instVarAt: 2 put: i * 10. objs at: i put: o].
        ^ 1
    ]
    T class >> primDefine: spec [
        <primitive: 145>
        ^ nil
    ]
    T class >> step2 [
        | b |
        b := Binding basicNew.
        b instVarAt: 1 put: #Scale.
        b instVarAt: 2 put: 3.
        (self redefine: {{{cls. 3. #(0 2 1)}}. {}. {{cls. {b}}}. nil}) == nil ifFalse: [^ -1].
        (self redefine: {{{cls class. 6. #(1 2 3 4 5 0)}}. {}. {}. nil}) == nil ifFalse: [^ -1].
        cls class == nil ifTrue: [^ -1].
        ^ 1
    ]
    T class >> step3 [
        gone := self primDefine: {#Gone. Object. #(). #(). #(). #fixed. nil. 0. 0}.
        (self remove: gone as: #AnObsoleteGone) == nil ifFalse: [^ -1].
        "refusals: a superclass that is not a class, a reshape that moves the class layout"
        (self primDefine: {#Bad. 3. #(). #(). #(). #fixed. nil. 0. 0}) == nil ifTrue: [^ -1].
        (self redefine: {{{cls class. 6. #(0 2 3 4 5 1)}}. {}. {}. nil}) == nil ifTrue: [^ -1].
        ^ 1
    ]
    """),
]

@Suite(.serialized) struct LiveClassTests {
    @Test func aClassDefinedAndReshapedAtRunTimeSavesAndLoads() throws {
        var o = KernelBuild.Options()
        o.initialize = false
        o.heapMiB = 64
        let built = try KernelBuild.build(liveClassFiles, options: o)
        let image = try Image.load(image: built.image)
        #expect(try answerOf(image, "T", "step1") == 1)
        #expect(try answerOf(image, "T", "step2") == 1)
        #expect(try answerOf(image, "T", "step3") == 1)
        let saved = image.saveImage()
        image.destroy()
        // A snapshot fuzzer seed with a class made and reshaped at run time.
        if ProcessInfo.processInfo.environment["KAJO_WRITE_FUZZ_SEEDS"] != nil {
            var url = URL(fileURLWithPath: #filePath)
            for _ in 0..<2 { url.deleteLastPathComponent() }
            try Data(saved).write(to: url.appendingPathComponent("KajoVMTests/Fixtures/fuzz/snapshot/live-class.img"))
        }
        // Every rule of the loader holds after the change.
        let again = try Image.load(image: saved)
        defer { again.destroy() }
        let om = again.om
        let pi = try #require(again.classIndex(named: "Point3"))
        #expect(om.classFormat(pi).namedSlots == 3)
        #expect(om.load(om.classOop(pi), ClassLayout.instSize) == Oop(smallInteger: 3))
        let objs = om.allInstances(of: pi)
        #expect(objs.count == 3)
        var seen: Set<Int64> = []
        for x in objs {
            #expect(om.count(of: x) == 3)
            #expect(om.load(x, 0) == again.nilObject)
            let xv = om.load(x, 2).smallIntegerValue, yv = om.load(x, 1).smallIntegerValue
            #expect(yv == 10 * xv)
            seen.insert(xv)
        }
        #expect(seen == [1, 2, 3])
        // the class side gained a slot; the pool is the one Binding
        let meta = again.metaclassIndex(of: pi)
        #expect(om.classFormat(meta).namedSlots == ClassLayout.size + 1)
        #expect(om.count(of: om.classOop(pi)) == UInt64(ClassLayout.size + 1))
        let pool = om.load(om.classOop(meta), MetaclassLayout.classPool)
        #expect(om.count(of: pool) == 1 && om.isReadOnly(pool))
        #expect(again.symbolName(om.load(om.load(pool, 0), BindingLayout.key)) == "Scale")
        // the removed class stays in the table, renamed and emptied
        #expect(again.classIndex(named: "Gone") == nil)
        let gi = try #require(again.classIndex(named: "AnObsoleteGone"))
        #expect(om.load(om.classOop(gi), ClassLayout.superclass) == again.nilObject)
    }

    @Test func theFilePrimitivesStayInTheirDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kajo-live-\(getpid())")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("out"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        let files = miniKernel + [tonel("F", "Object", """
        F class >> write: p contents: s [
            <primitive: 148>
            ^ nil
        ]
        F class >> read: p [
            <primitive: 149>
            ^ nil
        ]
        F class >> run [
            (self write: 'sub/a.txt' contents: 'hello') == true ifFalse: [^ -1].
            (self read: 'sub/a.txt') == nil ifTrue: [^ -2].
            (self write: 'sub/a.txt' contents: 'again') == true ifFalse: [^ -3].
            (self write: '/etc/x' contents: 'x') == nil ifFalse: [^ -4].
            (self write: '../x' contents: 'x') == nil ifFalse: [^ -5].
            (self write: 'sub/../../x' contents: 'x') == nil ifFalse: [^ -6].
            (self write: 'out/kajo-escape' contents: 'x') == nil ifFalse: [^ -7].
            (self write: 'none/x' contents: 'x') == nil ifFalse: [^ -8].
            (self read: 'nothing.txt') == nil ifFalse: [^ -9].
            (self write: '' contents: 'x') == nil ifFalse: [^ -10].
            (self write: #sym contents: 'x') == nil ifFalse: [^ -11].
            ^ 1
        ]
        F class >> withoutDirectory [
            ^ (self write: 'a.txt' contents: 'x') == nil ifTrue: [1] ifFalse: [-1]
        ]
        """)]
        var o = KernelBuild.Options()
        o.initialize = false
        o.heapMiB = 64
        let image = try Image.load(image: try KernelBuild.build(files, options: o).image)
        defer { image.destroy() }
        #expect(try answerOf(image, "F", "run", sources: dir.path) == 1)
        #expect(try String(contentsOf: dir.appendingPathComponent("sub/a.txt"), encoding: .utf8) == "again")
        #expect(!FileManager.default.fileExists(atPath: "/tmp/kajo-escape"))
        #expect(try answerOf(image, "F", "withoutDirectory") == 1)
        // a release image refuses them whatever the directory
        image.seal()
        #expect(try answerOf(image, "F", "withoutDirectory", sources: dir.path) == 1)
    }
}
