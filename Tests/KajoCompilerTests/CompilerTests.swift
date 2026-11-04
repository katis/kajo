// The bootstrap compiler on its own: the parser, the capture analysis and
// the code each construct compiles to, then methods compiled from Tonel
// files and run on a VM.

import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoVM

@Suite struct CompilerTests {
    @Test func aMethodCompilesToTheExpectedInstructions() throws {
        let m = try compile("foo: x [ ^ x + 1 ]".replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: ""))
        #expect(listing(m) == ["push_temp 0", "push_int 1", "add", "return_top"])
    }

    @Test func capturedAndAssignedVariablesLiveInATempVector() throws {
        let m = try compile("sum: a | s | s := 0. a do: [:e | s := s + e]. ^ s")
        #expect(listing(m).prefix(2) == ["push_new_array 1", "store_temp 1"])
        #expect(m.blocks.count == 1)
        #expect(m.blocks[0].copied == 1)
        #expect(listing(m.blocks[0]) == ["push_tv_slot 0 1", "push_temp 0", "add", "dup", "store_tv_slot 0 1", "block_return"])
    }

    /// Module 8d, Pharo's rule: a captured and assigned temp declared in an
    /// inlined loop body lives in a vector the body makes on every pass.
    @Test func aLoopBodysCapturedAssignedTempGetsAVectorPerIteration() throws {
        let m = try compile("f: n | bs | bs := Array new: n. 1 to: n do: [:i | | t | t := i * 2. bs at: i put: [t := t + 1]]. ^ bs")
        let l = listing(m)
        #expect(l.filter { $0.hasPrefix("push_new_array") }.count == 1)
        // The vector is made after the loop test, at the top of the body:
        // the instruction right after the loop's jump_if_false.
        let jf = try #require(l.firstIndex { $0.hasPrefix("jump_if_false") })
        #expect(l[jf + 1] == "push_new_array 1")
        #expect(l[jf + 2].hasPrefix("store_temp"))
        // The block copies the iteration's vector.
        #expect(m.blocks.count == 1 && m.blocks[0].copied == 1)
        // Nested loops: each level makes its own.
        let nested = try compile("f | bs | bs := Array new: 9. 1 to: 3 do: [:i | | a | a := i. 1 to: 3 do: [:j | | b | b := j. bs at: i - 1 * 3 + j put: [a := a + 1. b := b + 1. a + b]]]. ^ bs")
        #expect(listing(nested).filter { $0.hasPrefix("push_new_array") }.count == 2)
        #expect(nested.blocks[0].copied == 2)
        // A temp of an inlined conditional inside the loop belongs to the loop body.
        let cond = try compile("f: n | bs | bs := Array new: n. 1 to: n do: [:i | i > 0 ifTrue: [| t | t := i. bs at: i put: [t := t + 1]]]. ^ bs")
        let cl = listing(cond)
        #expect(cl.filter { $0.hasPrefix("push_new_array") }.count == 1)
        #expect(cl[try #require(cl.firstIndex { $0.hasPrefix("jump_if_false") }) + 1] == "push_new_array 1")
        // whileTrue: and timesRepeat: bodies too.
        for src in ["f | bs k | bs := Array new: 3. k := 0. [k < 3] whileTrue: [| t | k := k + 1. t := k. bs at: k put: [t := t + 1]]. ^ bs",
                    "f | bs k | bs := Array new: 3. k := 0. 3 timesRepeat: [| t | k := k + 1. t := k. bs at: k put: [t := t + 1]]. ^ bs"] {
            let w = listing(try compile(src))
            #expect(w.filter { $0.hasPrefix("push_new_array") }.count == 1, "\(src)")
            #expect(w.first?.hasPrefix("push_new_array") == false, "\(src)")
        }
    }

    @Test func loopsWithoutCapturedAssignedBodyTempsMakeNoVector() throws {
        // body temps not captured
        #expect(!listing(try compile("f: n | s | s := 0. 1 to: n do: [:i | | t | t := i * 2. s := s + t]. ^ s")).contains { $0.hasPrefix("push_new_array") })
        // body temps captured but never assigned after declaration: copied
        let copied = try compile("f: n | bs | bs := Array new: n. 1 to: n do: [:i | bs at: i put: [i]]. ^ bs")
        #expect(!listing(copied).contains { $0.hasPrefix("push_new_array") })
        // no body temps at all
        #expect(!listing(try compile("f: n | s | s := 0. 1 to: n do: [:i | s := s + i]. ^ s")).contains { $0.hasPrefix("push_new_array") })
        // a temp of the method captured and assigned inside a loop keeps the method's one vector, made once
        let outer = listing(try compile("f: n | s | s := 0. 1 to: n do: [:i | [s := s + i] value]. ^ s"))
        #expect(outer.filter { $0.hasPrefix("push_new_array") }.count == 1)
        #expect(outer.first == "push_new_array 1")
    }

    @Test func capturedButNeverAssignedVariablesAreCopied() throws {
        let m = try compile("f: a | k | k := 3. ^ [:x | x + a + k]")
        // k is assigned (before the capture): the rule puts it in a vector;
        // a, an argument, is copied.
        #expect(m.blocks[0].copied == 2)
        #expect(listing(m).contains("push_new_array 1"))
    }

    @Test func inlinedControlFlowHasNoClosures() throws {
        let m = try compile("f: n | t | t := 0. 1 to: n do: [:i | t := t + i]. n > 3 ifTrue: [t := 1] ifFalse: [t := 2]. [t < 100] whileTrue: [t := t * 2]. ^ t")
        #expect(m.blocks.isEmpty)
        #expect(!listing(m).contains { $0.hasPrefix("send") })
    }

    @Test func aNonLocalReturnMarksItsBlocksAsNeedingAHome() throws {
        let m = try compile("detect: a a do: [:e | e > 2 ifTrue: [^ e]]. ^ nil")
        #expect(m.blocks[0].flags & MethodFlags.needsHome != 0)
        #expect(listing(m.blocks[0]).contains("nonlocal_return"))
    }

    @Test func literalArraysAndDynamicArrays() throws {
        let m = try compile("f ^ #(1 $a 'b' #c (2 3) foo: true #[1 2]) , {1. 2}")
        #expect(m.literals.contains(.array([.integer(1), .character(97), .string([98]), .symbol("c"),
                                            .array([.integer(2), .integer(3)]), .symbol("foo:"), .trueObject, .byteArray([1, 2])])))
    }

    @Test func pragmasArePragmaLiteralsExceptTheCompilersOwn() throws {
        let m = try compile("f <primitive: 60> <slow> <tag: #x> ^ 1")
        #expect(m.primitive == 60)
        #expect(m.pragmas.map(\.selector) == ["slow", "tag:"])
    }

    @Test func malformedSourcesAreCompileErrors() {
        for bad in ["f ^", "f [", "f x := 1", "f: a a := 1", "f | a a |", "f ^ 1. 2", "f #(", "f 'abc", "f \"x", "f $",
                    "f ^ 16r", "f ^ 99r1", "f ^ self foo: ", "f ^ (1", "f <primitive: 0>", "f super := 1", "f ^ [:x 1]",
                    "f ^ #[256]", "f ^ thisContext := 1", "f ^ a ; b"] {
            #expect(throws: CompileError.self, "\(bad)") { _ = try compile(bad) }
        }
    }

    @Test func compiledMethodsRun() throws {
        let files = miniKernel + [tonel("T", "Object", classIvars: ["count"], """
        T class >> loops [
            | sum |
            sum := 0.
            1 to: 10 do: [:i | sum := sum + i].
            10 to: 1 by: -2 do: [:i | sum := sum + i].
            3 timesRepeat: [sum := sum + 100].
            [sum > 400] whileFalse: [sum := sum + 1].
            ^ sum
        ]
        T class >> closures [
            | a total |
            a := Array new: 4.
            1 to: 4 do: [:i | a at: i put: i * i].
            total := 0.
            a do: [:e | total := total + e].
            ^ total + (a inject: 0 into: [:x :y | x + y])
        ]
        T class >> detect [
            #(1 5 9) do: [:e | e > 4 ifTrue: [^ e]].
            ^ 0
        ]
        T class >> nils [
            | x y |
            y := x ifNil: [7].
            ^ (y ifNotNil: [:v | v + 1]) + (nil ifNil: [1] ifNotNil: [:v | 2]) + (3 ifNil: [10] ifNotNil: [:v | v])
        ]
        T class >> state [
            count := 5.
            count := count + 1.
            ^ count
        ]
        T class >> cascade [
            | a |
            a := Array new: 2.
            a at: 1 put: 10; at: 2 put: 20; yourself.
            ^ (a at: 1) + (a at: 2) + {1. 2. 3} size
        ]
        T class >> blocks [
            | b c |
            b := [:x | [:y | x + y]].
            c := b value: 10.
            ^ (c value: 5) + ([] value ifNil: [1]) + ([:p :q | p * q] value: 3 value: 4)
        ]
        T class >> logic [
            ^ ((3 > 2 and: [2 > 1]) ifTrue: [1] ifFalse: [0]) + ((3 < 2 or: [false]) ifTrue: [10] ifFalse: [20])
        ]
        """)]
        #expect(try runClassSide(files, "T", "loops") == 401)
        #expect(try runClassSide(files, "T", "closures") == 60)
        #expect(try runClassSide(files, "T", "detect") == 5)
        #expect(try runClassSide(files, "T", "nils") == 8 + 1 + 3)
        #expect(try runClassSide(files, "T", "state") == 6)
        #expect(try runClassSide(files, "T", "cascade") == 33)
        #expect(try runClassSide(files, "T", "blocks") == 15 + 1 + 12)
        #expect(try runClassSide(files, "T", "logic") == 21)
    }
}

/// The in-suite stand-in for `just fuzz syntax`: seeded mutations of
/// kernel class files and method sources (byte flips, deletions,
/// duplications, swaps) through the reader and the compiler; each ends in
/// a CompileError or a verified method.
@Test func mutatedSourcesCompileOrAreRefused() throws {
    let seeds = try KernelBuild.sources(in: [kernelDirectory]).prefix(40).map(\.text)
    var rng: UInt64 = 0x5EED_5EED
    func next(_ n: Int) -> Int {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Int((rng >> 33) % UInt64(max(n, 1)))
    }
    var compiled = 0
    for k in 0..<1500 {
        var b = seeds[k % seeds.count]
        for _ in 0..<(1 + next(4)) {
            guard !b.isEmpty else { break }
            let i = next(b.count)
            switch next(5) {
            case 0: b[i] ^= UInt8(1 << next(8))
            case 1: b.remove(at: i)
            case 2: b.insert(b[next(b.count)], at: i)
            case 3: b.swapAt(i, next(b.count))
            default: b[i] = Array("[]()^:=.;#$'\"|<>-0123456789e".utf8)[next(28)]
            }
        }
        if FuzzSyntax.run(b) { compiled += 1 }
    }
    #expect(compiled > 0)
}

/// The syntax fuzzer's crash in module 8c's gate run: a keyword send of
/// more than 255 arguments trapped in the assembler (the argument count is
/// one byte); it is a CompileError now.
@Test func aSendOfMoreThan255ArgumentsIsRefused() throws {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<2 { url.deleteLastPathComponent() }
    let b = [UInt8](try Data(contentsOf: url.appendingPathComponent("KajoVMTests/Fixtures/fuzz/syntax/crash-many-keywords.st")))
    #expect(!FuzzSyntax.run(b))
    let many = "f " + (1...300).map { "k\($0): 1" }.joined(separator: " ")
    #expect(throws: CompileError.self) { _ = try compileMethod(Array(("m ^ nil " + many).utf8), file: "t", in: FuzzSyntax.context) }
}

/// A compilation leaves nothing behind: the scopes and variables are freed
/// with the method's tree (a Variable's strong reference to its Scope made
/// a cycle, and the syntax fuzzer ran out of memory).
@Test func aCompilationFreesItsScopes() throws {
    weak var methodScope: Scope?
    weak var blockScope: Scope?
    weak var variable: Variable?
    do {
        let tree = try parseMethod(Array("f: a | t | t := 0. a do: [:e | t := t + e]. ^ [t]".utf8), file: "t")
        var c = Compiler(context: ClassContext(className: "Object", classSide: false, instanceVariables: [],
                                               isClassName: { _ in false }), file: "t")
        _ = try c.compile(tree)
        methodScope = tree.scope
        variable = tree.scope.declared.first
        blockScope = tree.scope.locals.first?.scope
        #expect(methodScope != nil && variable != nil && blockScope != nil)
    }
    #expect(methodScope == nil)
    #expect(variable == nil)
    #expect(blockScope == nil)
}
