// Module 8d: class variables. The bootstrap compiler's code for them, the
// image build's checks, the pools in the image and their round trip.

import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoVM

/// The kernel's Binding, as the tests' small class sets need it.
let bindingClass = tonel("Binding", "Object", ivars: ["key", "value"], """
Binding >> value [ ^ value ]
Binding >> value: v [ value := v. ^ v ]
""")

/// A class T with class variable Count, its subclass U, an unrelated V.
let classVariableFiles = miniKernel + [bindingClass, tonel("T", "Object", classVars: ["Count"], """
T >> count [ ^ Count ]
T >> bump [ ^ Count := Count + 1 ]
T class >> reset [ Count := 0. ^ 0 ]
T class >> count [ ^ Count ]
T class >> setTo: n [ Count := n ]
T class >> bumpFromInstance [ ^ self new bump ]
"""), tonel("U", "T", """
U class >> twiceBumped [ self new bump. ^ self new bump ]
U >> seen [ ^ Count ]
"""), tonel("V", "Object", "")]

@Suite struct ClassVariableTests {
    @Test func aClassVariableIsItsBindingAndValueSends() throws {
        let ctx = ClassContext(className: "T", classSide: false, instanceVariables: [], isClassName: { $0 == "Object" },
                               classVariables: ["Count": "T"])
        func listed(_ src: String) throws -> [String] { listing(try compileMethod(Array(src.utf8), file: "t", in: ctx).0) }
        let b = Literal.binding(owner: "T", name: "Count")
        #expect(try listed("f ^ Count") == ["push_lit \(b)", "value", "return_top"])
        #expect(try listed("f Count := 3") == ["push_lit \(b)", "push_int 3", "value1", "pop", "return_self"])
        #expect(try listed("f ^ Count := Count + 1") == ["push_lit \(b)", "push_lit \(b)", "value", "push_int 1", "add", "value1", "return_top"])
        // one literal for both uses
        #expect(try compileMethod(Array("f ^ Count := Count + 1".utf8), file: "t", in: ctx).0.literals == [b])
        // a temp, an argument or a block's argument may not shadow it
        for bad in ["f | Count | ^ 1", "f: Count ^ 1", "f ^ [:Count | 1]", "f ^ [| Count | 1]"] {
            #expect(throws: CompileError.self, "\(bad)") { _ = try listed(bad) }
        }
    }

    @Test func classVariablesAreSharedByBothSidesAndSubclasses() throws {
        #expect(try runClassSide(classVariableFiles, "T", "reset") == 0)
        // one VM per run: each starts from the image's nil, so each method sets first
        let files = classVariableFiles + [tonel("W", "Object", """
        W class >> run [
            T reset.
            T bumpFromInstance.
            U twiceBumped.
            ^ (T count * 100) + (U new seen * 10) + T new count
        ]
        """)]
        let got = Result { try runClassSide(files, "W", "run") }
        #expect((try? got.get()) == 333, "\(got)")
        // an unrelated class does not see it: the build refuses the method
        let unrelated = classVariableFiles + [tonel("X", "Object", "X >> f [ ^ Count ]")]
        #expect(throws: CompileError.self) { _ = try KernelBuild.build(unrelated, options: noInit) }
    }

    @Test func theBuildRefusesBadClassVariables() throws {
        // each refused, for its own reason (the message's words)
        let cases: [(String, String, [(file: String, text: [UInt8])])] = [
            ("lowercase", "capital", [tonel("A", "Object", classVars: ["count"], "")]),
            ("twice", "declared twice", [tonel("A", "Object", classVars: ["Count", "Count"], "")]),
            ("a superclass's", "shadows A's class variable",
             [tonel("A", "Object", classVars: ["Count"], ""), tonel("B", "A", classVars: ["Count"], "")]),
            ("an instance variable", "shadows an instance variable", [tonel("A", "Object", ivars: ["Count"], classVars: ["Count"], "")]),
            ("an inherited instance variable", "shadows an instance variable",
             [tonel("A", "Object", ivars: ["Count"], ""), tonel("B", "A", classVars: ["Count"], "")]),
            ("a class-side instance variable", "shadows a class-side instance variable",
             [tonel("A", "Object", classIvars: ["Count"], classVars: ["Count"], "")]),
            ("a subclass's instance variable", "instance variable Count shadows A's class variable",
             [tonel("A", "Object", classVars: ["Count"], ""), tonel("B", "A", ivars: ["Count"], "")]),
            ("a method temp", "'Count' shadows A's class variable", [tonel("A", "Object", classVars: ["Count"], "A >> f [ | Count | ^ 1 ]")]),
            ("a subclass's argument", "'Count' shadows A's class variable",
             [tonel("A", "Object", classVars: ["Count"], ""), tonel("B", "A", "B >> f: Count [ ^ 1 ]")]),
            ("no Binding class", "no class Binding", [tonel("A", "Object", classVars: ["Count"], "")]),
        ]
        for (what, words, extra) in cases {
            let base = what == "no Binding class" ? miniKernel : miniKernel + [bindingClass]
            do {
                _ = try KernelBuild.build(base + extra, options: noInit)
                Issue.record("\(what): built")
            } catch {
                #expect(error.message.contains(words), "\(what): \(error.message)")
            }
        }
    }

    /// The pool is in the metaclass; each method's literal is the pool's
    /// Binding itself, before and after a save and load, and a value set at
    /// run time is saved with it.
    @Test func theBindingSurvivesAnImageRoundTrip() throws {
        let built = try KernelBuild.build(classVariableFiles, options: noInit)
        let image = try Image.load(image: built.image)
        #expect(image.runToCompletion(className: "T", selector: "reset") == nil)
        // Count becomes 2 through the instance side, then a save and a load
        #expect(image.runToCompletion(className: "U", selector: "twiceBumped") == nil)
        let saved = image.saveImage()
        image.destroy()
        // A snapshot fuzzer seed with class pools (`KAJO_WRITE_FUZZ_SEEDS=1`).
        if ProcessInfo.processInfo.environment["KAJO_WRITE_FUZZ_SEEDS"] != nil {
            var url = URL(fileURLWithPath: #filePath)
            for _ in 0..<2 { url.deleteLastPathComponent() }
            try Data(saved).write(to: url.appendingPathComponent("KajoVMTests/Fixtures/fuzz/snapshot/class-pool.img"))
        }
        let again = try Image.load(image: saved)
        defer { again.destroy() }
        let om = again.om
        let ti = try #require(again.classIndex(named: "T"))
        let pool = om.load(om.classOop(again.metaclassIndex(of: ti)), MetaclassLayout.classPool)
        #expect(om.count(of: pool) == 1 && om.isReadOnly(pool))
        let binding = om.load(pool, 0)
        #expect(again.symbolName(om.load(binding, BindingLayout.key)) == "Count")
        #expect(om.load(binding, BindingLayout.value) == Oop(smallInteger: 2))
        // every method naming Count holds that very Binding
        let countSel = try #require(again.symbol("count"))
        let counter = try #require(again.lookup(again.metaclassIndex(of: ti), countSel))
        let lits = om.load(counter, MethodLayout.literals)
        #expect((0..<Int(om.count(of: lits))).contains { om.load(lits, $0) == binding })
        let ui = try #require(again.classIndex(named: "U"))
        let seenSel = try #require(again.symbol("seen"))
        let seen = try #require(again.lookup(ui, seenSel))
        #expect(om.load(om.load(seen, MethodLayout.literals), 0) == binding)
        // the other classes have no pool
        #expect(om.load(om.classOop(again.metaclassIndex(of: ui)), MetaclassLayout.classPool) == again.nilObject)
    }

    @Test func aBecomeOfTheValueIsSeenThroughTheBinding() throws {
        let files = classVariableFiles + [tonel("W", "Object", """
        W class >> run [
            | a b |
            a := Array new: 1.
            b := Array new: 2.
            T setTo: a.
            a become: b.
            ^ T count size
        ]
        """), tonel("Object2", "Object", "")]
        // `become:` (primitive 8) on Object; miniKernel lacks it
        let withBecome = files.map { f in
            f.file == "Object.class.st" ? (f.file, f.text + Array("\nObject >> become: o [ <primitive: 8> ^ nil ]\n".utf8)) : f
        }
        let got = Result { try runClassSide(withBecome, "W", "run") }
        #expect((try? got.get()) == 2, "\(got)")
    }
}

let noInit: KernelBuild.Options = {
    var o = KernelBuild.Options()
    o.initialize = false
    o.heapMiB = 64
    return o
}()
