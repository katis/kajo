// Types 1 (docs/modules/types-1.md): Strongtalk-style types in a method's
// pattern and in a class definition. Both compilers read the same grammar,
// keep the same types with the same ranges and refuse the same sources for
// the same reasons; a type compiles to nothing; both Tonel readers read the
// class-level keys alike and the image writes them back; a release image
// holds no class-level type.

import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoVM

/// The bootstrap's form of `Smalltalk typeDescriptionsOf:`.
func bootstrapTypes(_ source: String) -> String {
    do { return try parseMethod(Array(source.utf8), file: "types").typesDescription } catch {
        return "refused line \(error.line): \(error.message)"
    }
}

/// The pattern table: each place and each form of the grammar, with the
/// types kept and their ranges, and the refusals at the edges.
let typedPatterns: [(source: String, expected: String)] = [
    ("size ^<Integer>\n\t^ 3", "(name Integer 7 14)"),
    ("at: index <Integer> put: value <E> ^<E>\n\t^ value",
     "(name Integer 11 18)\n(name E 32 33)\n(name E 37 38)"),
    ("+ aNumber <Number> ^<Number>\n\t^ self", "(name Number 11 17)\n(name Number 21 27)"),
    ("< aMagnitude <Magnitude> ^<Boolean> ^ true", "(name Magnitude 14 23)\n(name Boolean 27 34)"),
    ("| aSet <Set[E]> ^<Set[E]> ^ aSet", "(name Set 8 14 (name E 12 13))\n(name Set 18 24 (name E 22 23))"),
    ("at: k <K> ifAbsent: aBlock <[^:X]> ^<V | X> ^ nil",
     "(name K 7 8)\n(block 28 33 ^(var X 30 32))\n(union 37 42 (name V 37 38) (name X 41 42))"),
    ("inject: a <:A> into: b <[A, E, ^A]> ^<A> ^ a",
     "(var A 11 13)\n(block 24 34 (name A 25 26) (name E 28 29) ^(name A 32 33))\n(name A 38 39)"),
    ("on: c <X class | ExceptionSet> do: b <[X, ^Dynamic]> ^<Dynamic> ^ nil",
     "(union 7 29 (class 7 14 (name X 7 8)) (name ExceptionSet 17 29))\n(block 38 51 (name X 39 40) ^(name Dynamic 43 50))\n(name Dynamic 55 62)"),
    ("new ^<Instance[X]> ^ nil", "(name Instance 6 17 (name X 15 16))"),
    ("class ^<Self class> ^ nil", "(class 8 18 (name Self 8 12))"),
    ("assert: b <Boolean | [^Boolean]> ^ self", "(union 11 31 (name Boolean 11 18) (block 21 31 ^(name Boolean 23 30)))\n-"),
    ("f: x <(Integer | Nil) class> ^ x", "(class 6 27 (union 7 20 (name Integer 7 14) (name Nil 17 20)))\n-"),
    ("at: k <Dictionary[K, Array[V | Nil]]> ^ k",
     "(name Dictionary 7 36 (name K 18 19) (name Array 21 35 (union 27 34 (name V 27 28) (name Nil 31 34))))\n-"),
    // overloads, by position
    ("+ aNumber <Integer; Number> ^<Integer; Number> ^ self",
     "(alt 11 26 (name Integer 11 18) (name Number 20 26))\n(alt 30 45 (name Integer 30 37) (name Number 39 45))"),
    ("max: a <Integer; Number> ^<Integer; Number> ^ self",
     "(alt 8 23 (name Integer 8 15) (name Number 17 23))\n(alt 27 42 (name Integer 27 34) (name Number 36 42))"),
    ("at: i <Integer> put: v <Integer; Float> ^<Integer; Float> ^ v",
     "(name Integer 7 14)\n(alt 24 38 (name Integer 24 31) (name Float 33 38))\n(alt 42 56 (name Integer 42 49) (name Float 51 56))"),
    // untyped places, pragmas beside types, comments inside a type
    ("at: i put: v <E> ^ v", "-\n(name E 14 15)\n-"),
    ("at: i <Integer> <primitive: 60> ^ nil", "(name Integer 7 14)\n-"),
    ("f: x <Integer> ^<Integer> <primitive: 60> | t | ^ x", "(name Integer 6 13)\n(name Integer 17 24)"),
    ("f: x <Integer \"a count\"> ^ x", "(name Integer 6 13)\n-"),
    ("f: x <unwind> ^ x", "-\n-"),
    ("f ^ 3", "-"),
    ("f ^ -3", "-"),
    // the > that ends a type is one character (starting position 2)
    ("f ^<Integer>| t | t := 1. ^ t", "(name Integer 4 11)"),
    ("f: x <Integer><primitive: 60> ^ x", "(name Integer 6 13)\n-"),
    ("f: x <Array[E]>^<E> ^ x", "(name Array 6 14 (name E 12 13))\n(name E 17 18)"),
    // refusals at the edges
    ("f: x <Integer ^ x", "refused line 1: expected > to end the type"),
    ("f: x <Integer> ^<Integer> <Integer> ^ x", "refused line 1: a type after the result"),
    ("f ^<Integer> <Integer> ^ 1", "refused line 1: a type after the result"),
    ("f ^<Integer> ^<Integer> ^ 1", "refused line 1: two result types"),
    ("f: x ^<Integer> g: y ^ x", "refused line 1: the result type follows the whole pattern"),
    ("f <Primitive: 60> ^ 1", "refused line 1: a pragma name starts with a lowercase letter"),
    ("f <Unwind> ^ 1", "refused line 1: a pragma name starts with a lowercase letter"),
    ("f | t | <Integer> ^ 1", "refused line 1: a pragma name starts with a lowercase letter"),
    ("f: x <Integer>> ^ x", "refused line 1: expected an expression"),
    ("f: x <Integer>>| t | ^ x", "refused line 1: expected an expression"),
    ("f: x <integer> ^ x", "-\n-"),  // a unary pragma: a lowercase name after < is never a type
    ("f: x <Array[integer]> ^ x", "refused line 1: a type name starts with a capital"),
    ("f: x <Array[]> ^ x", "refused line 1: expected a type"),
    ("f: x <Array[E> ^ x", "refused line 1: expected ] to end the type arguments"),
    ("f: x <[E]> ^ x", "refused line 1: a block type ends with ^ and its result type"),
    ("f: x <[E, ^R> ^ x", "refused line 1: expected ] to end the block type"),
    ("f: x <(Integer> ^ x", "refused line 1: expected ) in the type"),
    ("f: x <:x> ^ x", "refused line 1: expected a type variable's name after :"),
    ("f: x <Integer |> ^ x", "refused line 1: expected > to end the type"),  // |> is one binary token
    ("f: x <Integer | > ^ x", "refused line 1: expected a type"),
    ("f: x <Integer || Nil> ^ x", "refused line 1: expected > to end the type"),
    ("f: x <Integer;> ^ x", "refused line 1: expected a type"),
    ("f ^<Integer; Float> ^ 1", "refused line 1: a unary method has no overloads"),
    ("f: x <A; B> ^<A; B; C> ^ x", "refused line 1: overloads give every place the same number of alternatives"),
    ("f: x\n\t<Integer\n\t^ x", "refused line 3: expected > to end the type"),
]

/// Nesting at and past the parser's limit, in every bracket a type has.
func nestedTypes(_ d: Int) -> [String] {
    func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }
    return ["f: x <" + rep("A[", d - 1) + "A" + rep("]", d - 1) + "> ^ x",
            "f ^<" + rep("[^", d - 1) + "A" + rep("]", d - 1) + ">",
            "f: x <" + rep("(", d - 1) + "A" + rep(")", d - 1) + "> ^ x"]
}

/// Every method of the Tonel files of `directories` whose pattern holds a
/// type, with its class's context.
func typedMethods(_ directories: [String]) throws -> [(name: String, source: [UInt8], context: ClassContext, spans: [(start: Int, end: Int)])] {
    let files = try KernelBuild.sources(in: directories)
    let plan = try Plan(files)
    let known = Set(plan.classes.map(\.name)).union(Image.wellKnownClasses.map(\.name))
    var out: [(String, [UInt8], ClassContext, [(start: Int, end: Int)])] = []
    for c in plan.classes {
        for m in c.methods {
            var p = try Parser(m.source, file: c.file)
            _ = try p.parsePattern()
            guard !p.typeSpans.isEmpty else { continue }
            let ctx = ClassContext(className: c.name, classSide: m.classSide,
                                   instanceVariables: m.classSide ? plan.classInstanceVariables[c.name] ?? [] : plan.instanceVariables[c.name] ?? [],
                                   firstSlot: m.classSide ? Image.classLayoutSize : 0, isClassName: { known.contains($0) },
                                   classVariables: plan.classVariables[c.name] ?? [:])
            out.append(("\(c.name)\(m.classSide ? " class" : "")>>\(String(decoding: m.source.prefix(40), as: UTF8.self))", m.source, ctx, p.typeSpans))
        }
    }
    return out
}

/// `source` with each type span (and a result's `^`) blanked or removed.
func withoutTypes(_ source: [UInt8], _ spans: [(start: Int, end: Int)], blank: Bool) -> [UInt8] {
    var s = source
    for sp in spans.reversed() {
        var a = sp.start
        if a > 0 && s[a - 1] == 94 { a -= 1 }  // the result's ^
        if blank {
            for k in a..<sp.end where s[k] != 10 { s[k] = 32 }
        } else {
            while a > 0 && s[a - 1] == 32 { a -= 1 }
            s.removeSubrange(a..<sp.end)
        }
    }
    return s
}

/// nil when two methods hold the same code (the source map's ranges
/// shifted by `shift` from b to a), else the first difference.
func sameCode(_ a: AssembledMethod, _ b: AssembledMethod, shift: Int) -> String? {
    if a.bytecodes != b.bytecodes { return "bytecodes" }
    if a.argc != b.argc || a.temps != b.temps || a.maxStack != b.maxStack || a.primitive != b.primitive || a.flags != b.flags { return "header" }
    if a.literals.count != b.literals.count { return "literal count" }
    let hasMap = a.flags & MethodFlags.sourceMap != 0
    for (k, (x, y)) in zip(a.literals, b.literals).enumerated() {
        if hasMap && k == a.literals.count - 1, case .byteArray(let mx) = x, case .byteArray(let my) = y {
            guard let ex = SourceMap.decode(mx), let ey = SourceMap.decode(my) else { return "a map that does not decode" }
            if ex.count != ey.count || zip(ex, ey).contains(where: { $0.pc != $1.pc || $0.start != $1.start + shift || $0.end != $1.end + shift }) {
                return "source map"
            }
            continue
        }
        if x != y { return "literal \(k)" }
    }
    if a.blocks.count != b.blocks.count { return "block count" }
    for (x, y) in zip(a.blocks, b.blocks) { if let d = sameCode(x, y, shift: shift) { return "block: \(d)" } }
    if a.pragmas.count != b.pragmas.count { return "pragmas" }
    return nil
}

@Suite(.serialized) struct TypesTests {
    /// Both parsers keep the table's types with the same ranges and refuse
    /// its refusals for the same reasons at the same lines.
    @Test func bothParsersReadTheTableAlike() throws {
        let sources = typedPatterns.map(\.source) + (31...33).flatMap(nestedTypes)
        let mine = sources.map(bootstrapTypes)
        for (k, e) in typedPatterns.enumerated() {
            #expect(mine[k] == e.expected, "\(e.source)")
        }
        for (k, d) in (31...33).enumerated() {
            for s in mine[(typedPatterns.count + 3 * k)..<(typedPatterns.count + 3 * k + 3)] {
                #expect(s.hasPrefix("refused") == (d > Parser.maxDepth), "depth \(d): \(s)")
            }
        }
        let image = try Image.load(image: kernelImage)
        defer { image.destroy() }
        let theirs = try smalltalkStrings(image, "typeDescriptionsOf:", sources)
        #expect(theirs.count == sources.count)
        var differ: [String] = []
        for (k, s) in sources.enumerated() where k < theirs.count && theirs[k] != mine[k] {
            differ.append("\(s.prefix(50)): \(mine[k]) | \(theirs[k])")
        }
        #expect(differ.isEmpty, "\(differ.count) differ: \(differ.prefix(5))")
    }

    /// Starting position 4: every typed method of kernel/, compiled with its
    /// types, with them blanked and with them removed, is the same method
    /// (the source map's ranges shifted by what was removed), and with the
    /// blanks around each type's < and > squeezed out it reads the same
    /// types and compiles the same. KAJO_TYPES_OUT names a file the count
    /// is written to.
    @Test func typesCompileToNothing() throws {
        let methods = try typedMethods([kernelDirectory])
        #expect(methods.count >= 577)
        var failures: [String] = []
        for m in methods {
            let typed = try compileMethod(m.source, file: "typed", in: m.context).0
            let blanked = try compileMethod(withoutTypes(m.source, m.spans, blank: true), file: "blank", in: m.context).0
            if let d = sameCode(typed, blanked, shift: 0) { failures.append("\(m.name) blanked: \(d)") }
            let removedSource = withoutTypes(m.source, m.spans, blank: false)
            let removed = try compileMethod(removedSource, file: "removed", in: m.context).0
            if let d = sameCode(typed, removed, shift: m.source.count - removedSource.count) { failures.append("\(m.name) removed: \(d)") }
            // the slice's signatures with no blank before a type's < or after its >
            var squeezed = m.source
            for sp in m.spans.reversed() {
                if sp.end < squeezed.count && squeezed[sp.end] == 32 { squeezed.remove(at: sp.end) }
                var a = sp.start
                if a > 0 && squeezed[a - 1] == 94 { a -= 1 }
                if a > 0 && squeezed[a - 1] == 32 { squeezed.remove(at: a - 1) }
            }
            let tq = try parseMethod(squeezed, file: "squeezed"), to = try parseMethod(m.source, file: "typed")
            func shape(_ t: TypeNode?) -> String { (t?.description ?? "-").replacingOccurrences(of: #" \d+ \d+"#, with: "", options: .regularExpression) }
            if zip(tq.argumentTypes, to.argumentTypes).contains(where: { shape($0) != shape($1) }) || shape(tq.resultType) != shape(to.resultType) {
                failures.append("\(m.name) squeezed: other types")
            }
            let sq = try compileMethod(squeezed, file: "squeezed", in: m.context).0
            if sq.bytecodes != typed.bytecodes { failures.append("\(m.name) squeezed: bytecodes") }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(methods.count): \(failures.prefix(5))")
        if let out = ProcessInfo.processInfo.environment["KAJO_TYPES_OUT"] {
            try? "typed methods \(methods.count), differing \(failures.count)\n".write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    /// The class-level keys: both readers take them alike (the readers'
    /// test compares every kernel file), the image writes a typed class
    /// back byte for byte, and a malformed key is refused alike.
    @Test func theClassLevelKeysAreReadAlikeAndRefusedAlike() throws {
        func file(_ keys: String, ivars: String = "'a <Integer>'") -> String {
            "Class {\n\t#name : #TypesProbe,\n\t#superclass : #Object,\n\(keys)\t#instVars : [\n\t\t\(ivars)\n\t]\n}\n"
        }
        let cases: [String] = [
            file("\t#typeParameters : [\n\t\t'E'\n\t],\n\t#superclassType : 'Object',\n"),
            file("", ivars: "'a <Array[E | Nil]> b'"),
            file("", ivars: "'a <Integer> \"a count\"'"),
            file("\t#typeParameters : [\n\t\t'e'\n\t],\n"),
            file("\t#typeParameters : [\n\t\t'E',\n\t\t'E'\n\t],\n"),
            file("\t#typeParameters : #E,\n"),
            file("\t#superclassType : 'Magnitude',\n"),
            file("\t#superclassType : 'Object[',\n"),
            file("\t#superclassType : #Object,\n"),
            file("", ivars: "'a <:X>'"),
            file("", ivars: "'a <A; B>'"),
            file("", ivars: "'a <Integer'"),
            file("", ivars: "'a-b'"),
            file("", ivars: "'a <integer>'"),
        ]
        let mine = cases.map { c -> String in
            do { return swiftSummary(try readTonel(Array(c.utf8), file: "probe")) } catch let e as CompileError { return "refused \(e.line): \(e.message)" } catch { return "\(error)" }
        }
        #expect(!mine[0].hasPrefix("refused") && !mine[1].hasPrefix("refused") && !mine[2].hasPrefix("refused"), "\(mine.prefix(3))")
        #expect(mine[3...].allSatisfy { $0.hasPrefix("refused") }, "\(mine)")
        let image = try Image.load(image: kernelImage)
        defer { image.destroy() }
        let theirs = try smalltalkStrings(image, "evaluateStrings:", cases.map { c in
            "[(TonelReader read: '\(c.replacingOccurrences(of: "'", with: "''"))') summary] on: CompileError do: [:e | 'refused ' , e line printString , ': ' , e reason]"
        })
        #expect(theirs == mine, "\(zip(theirs, mine).filter { $0 != $1 }.prefix(3))")
    }

    /// A release image built from the typed kernel holds no class-level
    /// type: a marker type name that appears only in a class definition's
    /// types is in the development image's bytes and not in the release
    /// image's. Its methods' types stay, as their sources do.
    @Test func aReleaseImageHoldsNoClassLevelType() throws {
        let dir = try temporaryDirectory("types-release")
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = "QzvMarkerType"
        let probe = "Class {\n\t#name : #TypesMarker,\n\t#superclass : #Object,\n\t#typeParameters : [\n\t\t'\(marker)P'\n\t],\n"
            + "\t#superclassType : 'Object',\n\t#instVars : [\n\t\t'a <\(marker)[Integer]>'\n\t]\n}\n\n"
            + "{ #category : #accessing }\nTypesMarker >> a ^<MethodQzvType> [\n\t^ a\n]\n"
        try probe.write(to: dir.appendingPathComponent("TypesMarker.class.st"), atomically: true, encoding: .utf8)
        let files = try KernelBuild.sources(in: [kernelDirectory, dir.path])
        var options = KernelBuild.Options()
        let development = try KernelBuild.build(files, options: options).image
        options.release = true
        let release = try KernelBuild.build(files, options: options).image
        func count(_ s: String, _ bytes: [UInt8]) -> Int {
            let n = Array(s.utf8)
            var c = 0
            var i = 0
            while i + n.count <= bytes.count {
                if bytes[i] == n[0] && Array(bytes[i..<(i + n.count)]) == n { c += 1; i += n.count } else { i += 1 }
            }
            return c
        }
        #expect(count(marker, development) > 0)
        #expect(count(marker, release) == 0)
        #expect(count("MethodQzvType", release) > 0)
        // and the development image writes the class back as it was read
        let image = try Image.load(image: development)
        defer { image.destroy() }
        #expect(try smalltalkStrings(image, "tonelSourcesOf:", ["TypesMarker"]) == [probe])
        // the release image writes the class with no type key
        let r = try Image.load(image: release)
        defer { r.destroy() }
        let written = try smalltalkStrings(r, "tonelSourcesOf:", ["TypesMarker"])
        #expect(written.count == 1 && !written[0].contains(marker) && written[0].contains("^<MethodQzvType>"), "\(written)")
    }
}
