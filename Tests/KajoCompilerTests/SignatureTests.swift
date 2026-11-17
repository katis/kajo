// Types 2 (docs/modules/types-2.md), part 2: a signature without a method.
// A method entry with no body: the same metadata and `Class [class] >>
// pattern` with its types, and nothing after the pattern but the next
// entry's `{` or the end of the file. Both Tonel readers read it alike and
// refuse alike; the image keeps its text in the class's ClassTypes (never a
// method: nothing is compiled for it), writes it back in the canonical order
// byte for byte, and a release build keeps none.

import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoVM

/// A class file of the probe class with `entries` after its definition.
func signatureProbeFile(_ entries: String, name: String = "SigProbe") -> String {
    "Class {\n\t#name : #\(name),\n\t#superclass : #Object\n}\n" + entries
}

/// The reader cases: accepted ones first (the count is `acceptedSignatureCases`).
let signatureCases: [String] = [
    // a signature first, then a method
    signatureProbeFile("\n{ #category : #accessing }\nSigProbe >> at: index <Integer> ^<Integer>\n\n{ #category : #accessing }\nSigProbe >> b [\n\t^ 1\n]\n"),
    // a method, then a signature last (the end of the file ends it)
    signatureProbeFile("\n{ #category : #accessing }\nSigProbe >> b [\n\t^ 1\n]\n\n{ #category : #accessing }\nSigProbe >> at: index <Integer> ^<Integer>\n"),
    // between two methods, and with no line break at the end of the file
    signatureProbeFile("\n{ #category : #a }\nSigProbe >> a [\n\t^ 1\n]\n\n{ #category : #a }\nSigProbe >> at: i <Integer> put: v <E> ^<E>\n\n{ #category : #a }\nSigProbe >> c [\n\t^ 2\n]"),
    // the class side, with overloads
    signatureProbeFile("\n{ #category : #'instance creation' }\nSigProbe class >> make: n <Integer; Float> ^<Instance; Instance>\n"),
    // method variables, a block type with brackets in the pattern
    signatureProbeFile("\n{ #category : #enumerating }\nSigProbe >> collect: aBlock <[Integer, ^:X]> ^<Array[X]>\n\n{ #category : #enumerating }\nSigProbe >> inject: a <:A> into: b <[A, Integer, ^A]> ^<A>\n"),
    // a comment after a signature, then the next entry
    signatureProbeFile("\n{ #category : #accessing }\nSigProbe >> size ^<Integer> \"a note\"\n\n{ #category : #accessing }\nSigProbe >> b [\n\t^ 1\n]\n"),
    // no metadata (no category), one type on an argument only, a binary pattern
    signatureProbeFile("\nSigProbe >> + aNumber <Number>\n\n{ #category : #x }\nSigProbe >> b [ ^ 1 ]\n"),
    // the same selector on both sides
    signatureProbeFile("\n{ #category : #a }\nSigProbe >> size ^<Integer>\n\n{ #category : #a }\nSigProbe class >> size ^<Integer>\n"),
    // refused: a method and a signature for one selector, either order
    signatureProbeFile("\n{ #category : #a }\nSigProbe >> b ^<Integer>\n\n{ #category : #a }\nSigProbe >> b [\n\t^ 1\n]\n"),
    signatureProbeFile("\n{ #category : #a }\nSigProbe >> b [\n\t^ 1\n]\n\n{ #category : #a }\nSigProbe >> b ^<Integer>\n"),
    // refused: a signature twice
    signatureProbeFile("\n{ #category : #a }\nSigProbe >> b ^<Integer>\n\n{ #category : #b }\nSigProbe >> b ^<String>\n"),
    // refused: a forgotten [ before statements, before a comment, before an empty body
    signatureProbeFile("\n{ #category : #a }\nSigProbe >> b\n\t^ 1\n]\n"),
    signatureProbeFile("\n{ #category : #a }\nSigProbe >> b: x\n\t\"the comment\"\n\t^ x\n]\n"),
    signatureProbeFile("\n{ #category : #a }\nSigProbe >> b\n]\n"),
    // refused: a signature without a type
    signatureProbeFile("\n{ #category : #a }\nSigProbe >> b\n\n{ #category : #a }\nSigProbe >> c [ ]\n"),
    signatureProbeFile("\n{ #category : #a }\nSigProbe >> b: x\n"),
    // refused: a signature, then a method entry without metadata
    signatureProbeFile("\n{ #category : #a }\nSigProbe >> f ^<Integer>\nSigProbe >> g [ ]\n"),
    // refused: a signature of another class in the file
    signatureProbeFile("\n{ #category : #a }\nObject >> f ^<Integer>\n"),
]
let acceptedSignatureCases = 8

/// One canonical class file with signatures in every place: first in its
/// category, between methods, alone in a category, on the class side, with
/// overloads and method variables. The image writes it back byte for byte.
let canonicalSignatureProbe = """
"A probe of signatures without a method (Types 2)."
Class {
\t#name : #SigProbe,
\t#superclass : #Object,
\t#instVars : [
\t\t'items'
\t]
}

{ #category : #accessing }
SigProbe >> at: index <Integer> ^<Integer>

{ #category : #accessing }
SigProbe >> b [
\t^ 1
]

{ #category : #accessing }
SigProbe >> c: x <Integer; Float> ^<Integer; Float>

{ #category : #enumerating }
SigProbe >> collect: aBlock <[Integer, ^:X]> ^<Array[X]>

{ #category : #'instance creation' }
SigProbe class >> make: n <Integer> ^<Instance>

{ #category : #'instance creation' }
SigProbe class >> new [
\t^ super new
]

"""

@Suite(.serialized) struct SignatureTests {
    /// The table through both readers: the accepted files read to the same
    /// fields, the refused ones refused at the same line for the same reason.
    @Test func bothReadersReadAndRefuseTheTableAlike() throws {
        let mine = signatureCases.map { c -> String in
            do { return swiftSummary(try readTonel(Array(c.utf8), file: "probe")) } catch let e as CompileError { return "refused \(e.line): \(e.message)" } catch { return "\(error)" }
        }
        #expect(mine.prefix(acceptedSignatureCases).allSatisfy { !$0.hasPrefix("refused") }, "\(mine.prefix(acceptedSignatureCases))")
        #expect(mine.dropFirst(acceptedSignatureCases).allSatisfy { $0.hasPrefix("refused") }, "\(mine.dropFirst(acceptedSignatureCases))")
        // The reasons, as the bootstrap gives them.
        let reasons = mine.dropFirst(acceptedSignatureCases).map { $0 }
        #expect(reasons == [
            "refused 10: SigProbe>>b is both a method and a signature",
            "refused 12: SigProbe>>b is both a method and a signature",
            "refused 10: a signature for SigProbe>>b twice",
            "refused 8: expected [ after the method's pattern",
            "refused 9: expected [ after the method's pattern",
            "refused 8: expected [ after the method's pattern",
            "refused 7: a signature writes at least one type",
            "refused 7: a signature writes at least one type",
            "refused 8: expected [ after the method's pattern",
            "refused 7: a method of Object in SigProbe's file",
        ], "\(reasons)")
        let accepted = try readTonel(Array(signatureCases[4].utf8), file: "probe")
        #expect(accepted.methods.isEmpty && accepted.signatures.map(\.selector) == ["collect:", "inject:into:"])
        #expect(String(decoding: accepted.signatures[0].text, as: UTF8.self) == "collect: aBlock <[Integer, ^:X]> ^<Array[X]>")
        let image = try Image.load(image: kernelImage)
        defer { image.destroy() }
        let theirs = try smalltalkStrings(image, "evaluateStrings:", signatureCases.map { c in
            "[(TonelReader read: '\(c.replacingOccurrences(of: "'", with: "''"))') summary] on: CompileError do: [:e | 'refused ' , e line printString , ': ' , e reason]"
        })
        #expect(theirs == mine, "\(zip(theirs, mine).filter { $0 != $1 }.prefix(3))")
    }

    /// A signature is not compiled: the image built with the probe has its
    /// two methods and no more, the class neither includes nor answers a
    /// signature's selector, and the signature's text is in its ClassTypes.
    /// The compilers' corpus is method sources, so it holds no signature and
    /// is not affected.
    @Test func aSignatureIsNotCompiled() throws {
        let dir = try temporaryDirectory("signatures")
        defer { try? FileManager.default.removeItem(at: dir) }
        try canonicalSignatureProbe.write(to: dir.appendingPathComponent("SigProbe.class.st"), atomically: true, encoding: .utf8)
        let plain = try KernelBuild.build(KernelBuild.sources(in: [kernelDirectory]))
        let built = try KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, dir.path]))
        #expect(built.methods == plain.methods + 2)
        let image = try Image.load(image: built.image)
        defer { image.destroy() }
        let answers = try smalltalkStrings(image, "evaluateStrings:", [
            "SigProbe selectors asArray sort printString",
            "SigProbe class selectors asArray sort printString",
            "(SigProbe includesSelector: #at:) printString , ' ' , (SigProbe new respondsTo: #collect:) printString",
            "(SigProbe signatureAt: #collect:) , ' | ' , (SigProbe class signatureAt: #make:)",
            "(Smalltalk signatureOf: #c: in: SigProbe) printString",
        ])
        #expect(answers == ["#(#b)", "#(#new)", "false false", "collect: aBlock <[Integer, ^:X]> ^<Array[X]> | make: n <Integer> ^<Instance>",
                            "#('c: x <Integer; Float> ^<Integer; Float>' #accessing nil)"], "\(answers)")
        let corpusPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/compiler-corpus/corpus.txt").path
        let corpus = try String(contentsOfFile: corpusPath, encoding: .utf8)
        #expect(!corpus.contains("SigProbe"))
    }

    /// The round trip: the image writes the probe back byte for byte (each
    /// signature among the methods in the canonical order), reads that text
    /// back into itself and writes it again the same; a release build of the
    /// same files keeps no signature's text and writes the class without one.
    @Test func theProbeRoundTripsAndAReleaseBuildDropsItsSignatures() throws {
        let dir = try temporaryDirectory("signatures-trip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = "QzvSigMarker"
        let probe = canonicalSignatureProbe.replacingOccurrences(of: "^<Array[X]>", with: "^<Array[X] | \(marker)>")
        try probe.write(to: dir.appendingPathComponent("SigProbe.class.st"), atomically: true, encoding: .utf8)
        let files = try KernelBuild.sources(in: [kernelDirectory, dir.path])
        var options = KernelBuild.Options()
        let development = try KernelBuild.build(files, options: options).image
        options.release = true
        let release = try KernelBuild.build(files, options: options).image
        #expect(occurrences(marker, development) > 0)
        #expect(occurrences(marker, release) == 0)
        let image = try Image.load(image: development)
        defer { image.destroy() }
        #expect(try smalltalkStrings(image, "tonelSourcesOf:", ["SigProbe"]) == [probe])
        #expect(try smalltalkStrings(image, "readTonelAll:", [probe]) == [probe])
        let r = try Image.load(image: release)
        defer { r.destroy() }
        let written = try smalltalkStrings(r, "tonelSourcesOf:", ["SigProbe"])
        #expect(written.count == 1 && !written[0].contains(" ^<") && written[0].contains("SigProbe >> b ["), "\(written)")
    }

    /// Live: a signature added in the image is written back in its place; a
    /// method compiled where a signature stands replaces it (open question
    /// 2) and keeps its category; a signature is refused where a method
    /// stands, without a type, or as more than a pattern; removed, it goes.
    @Test func signaturesChangeInTheImageAndTheFileFollows() throws {
        let dir = try temporaryDirectory("signatures-live")
        defer { try? FileManager.default.removeItem(at: dir) }
        try canonicalSignatureProbe.write(to: dir.appendingPathComponent("SigProbe.class.st"), atomically: true, encoding: .utf8)
        let image = try Image.load(image: KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, dir.path])).image)
        defer { image.destroy() }
        let answers = try smalltalkStrings(image, "evaluateStrings:", [
            "SigProbe signature: 'd: y <String> ^<String>' classified: #accessing",
            "SigProbe compile: 'c: x\n\t^ x'",
            "(SigProbe signatureAt: #c:) printString , ' ' , (SigProbe categoryOf: #c:)",
            "[SigProbe signature: 'b ^<Integer>' classified: #x. 'added'] on: Error do: [:e | e messageText]",
            "[SigProbe signature: 'e: z' classified: #x. 'added'] on: CompileError do: [:e | e reason]",
            "[SigProbe signature: 'e: z <Integer> ^ z' classified: #x. 'added'] on: CompileError do: [:e | e reason]",
            "SigProbe tonelSource",
            "(SigProbe removeSignature: #d:) , ' ' , (SigProbe removeSignature: #d:) printString",
            "(SigProbe tonelSource includesSubstring: 'd: y') printString",
        ])
        #expect(answers.count == 9)
        guard answers.count == 9 else { return }
        #expect(answers[0] == "d:" && answers[1] == "c:" && answers[2] == "nil accessing", "\(answers.prefix(3))")
        #expect(answers[3] == "SigProbe>>b is a method: a class has a method or a signature for a selector")
        #expect(answers[4] == "a signature writes at least one type")
        #expect(answers[5] == "a signature is a message pattern alone")
        let expected = canonicalSignatureProbe
            .replacingOccurrences(of: "SigProbe >> c: x <Integer; Float> ^<Integer; Float>\n",
                                  with: "SigProbe >> c: x [\n\t^ x\n]\n\n{ #category : #accessing }\nSigProbe >> d: y <String> ^<String>\n")
        #expect(answers[6] == expected, "\(answers[6])")
        #expect(answers[7] == "d: y <String> ^<String> nil" && answers[8] == "false")
    }
}

/// How many times `s` occurs in `bytes`.
func occurrences(_ s: String, _ bytes: [UInt8]) -> Int {
    let n = Array(s.utf8)
    var c = 0
    var i = 0
    while i + n.count <= bytes.count {
        if bytes[i] == n[0] && Array(bytes[i..<(i + n.count)]) == n { c += 1; i += n.count } else { i += 1 }
    }
    return c
}
