import Foundation
import KajoVM

/// The image build (module 8b): Tonel files to a verified image. Every
/// class is defined (the well-known ones re-parented as their files say),
/// every method compiled by the bootstrap compiler and verified by the
/// assembler, a synthesized `Smalltalk class >> kernelDefinitions` records
/// the class definitions for the kernel's own tools (the compiler in
/// Smalltalk reads instance variable names from it), the entry point is
/// `Smalltalk`, and the kernel's class-side `initialize` methods run in a
/// VM before the image is saved. Any error refuses the whole build.
public struct KernelBuild: Sendable {
    public struct Options: Sendable {
        /// Run `Smalltalk initializeKernel` in a VM before saving.
        public var initialize = true
        public var heapMiB = 512
        public init() {}
    }

    public struct Result: Sendable {
        public let image: [UInt8]
        public let classes: Int
        public let methods: Int
        /// Compile warnings (unconsumed pragmas), one line each.
        public let warnings: [String]
    }

    /// The `.st` files of the directories, each directory's in name order.
    public static func sources(in directories: [String]) throws(CompileError) -> [(file: String, text: [UInt8])] {
        var out: [(String, [UInt8])] = []
        for d in directories {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: d) else {
                // a single file
                guard let data = FileManager.default.contents(atPath: d) else { throw CompileError("cannot read \(d)") }
                out.append((d, [UInt8](data)))
                continue
            }
            for n in names.sorted() where n.hasSuffix(".st") {
                let p = (d as NSString).appendingPathComponent(n)
                guard let data = FileManager.default.contents(atPath: p) else { throw CompileError("cannot read \(p)") }
                out.append((p, [UInt8](data)))
            }
        }
        return out
    }

    /// Build an image from Tonel sources.
    public static func build(_ files: [(file: String, text: [UInt8])], options: Options = Options()) throws(CompileError) -> Result {
        let plan = try Plan(files)
        let image: Image
        do { image = try Image.bootForKernel(heapMiB: options.heapMiB) } catch { throw CompileError(error.message) }
        defer { image.destroyImage() }
        try plan.load(into: image)
        if options.initialize && image.hasClass("Smalltalk") {
            if let problem = image.runToCompletion(className: "Smalltalk", selector: "initializeKernel") {
                throw CompileError("Smalltalk initializeKernel: \(problem)")
            }
            // Every method's source, kept in the image (Smalltalk sourceOf:),
            // in Arrays of at most 2000 Strings: "Class[ class]\nselector\nsource".
            let sources = plan.sources
            var start = 0
            while start < sources.count {
                let chunk = Array(sources[start..<min(sources.count, start + 2000)])
                if let problem = image.runToCompletion(className: "Smalltalk", selector: "recordSources:", strings: chunk) {
                    throw CompileError("Smalltalk recordSources: \(problem)")
                }
                start += chunk.count
            }
        }
        return Result(image: image.imageBytes(), classes: plan.classes.count, methods: plan.compiled.count, warnings: plan.warnings)
    }
}

/// The classes in definition order, every method compiled, the warnings.
struct Plan {
    var classes: [TonelClass] = []
    var definitions: [KernelClassDefinition] = []
    var compiled: [AssembledMethod] = []
    /// "Class[ class]\nselector\nsource" per compiled method.
    var sources: [String] = []
    var warnings: [String] = []
    /// Instance variable names (inherited first) and class-side ones.
    var instanceVariables: [String: [String]] = [:]
    var classInstanceVariables: [String: [String]] = [:]

    init(_ files: [(file: String, text: [UInt8])]) throws(CompileError) {
        var defs: [TonelClass] = []
        var extensions: [TonelClass] = []
        for f in files {
            let c = try readTonel(f.text, file: f.file)
            if c.isExtension { extensions.append(c) } else { defs.append(c) }
        }
        // Superclasses first; names unique.
        var byName: [String: TonelClass] = [:]
        for c in defs {
            if byName[c.name] != nil { throw CompileError("class \(c.name) defined twice", file: c.file, line: c.line) }
            byName[c.name] = c
        }
        let wellKnown = Dictionary(uniqueKeysWithValues: Image.wellKnownClasses.map { ($0.name, $0) })
        var ordered: [TonelClass] = []
        var placed = Set<String>()
        var visiting = Set<String>()
        func place(_ c: TonelClass) throws(CompileError) {
            if placed.contains(c.name) { return }
            if !visiting.insert(c.name).inserted { throw CompileError("superclass cycle through \(c.name)", file: c.file, line: c.line) }
            if let s = c.superclass {
                if let sc = byName[s] { try place(sc) }
                else if wellKnown[s] == nil { throw CompileError("unknown superclass \(s)", file: c.file, line: c.line) }
            }
            placed.insert(c.name)
            ordered.append(c)
        }
        for c in defs.sorted(by: { $0.name < $1.name }) { try place(c) }
        classes = ordered

        // Layouts: inherited names first; the format inherited unless given.
        var kinds: [String: String] = [:]
        for w in Image.wellKnownClasses {
            kinds[w.name] = w.kind
            instanceVariables[w.name] = (0..<w.instSize).map { "slot\($0)" }
            classInstanceVariables[w.name] = []
        }
        for c in ordered {
            let inherited = c.superclass.map { instanceVariables[$0] ?? [] } ?? []
            let inheritedMeta = c.superclass.map { classInstanceVariables[$0] ?? [] } ?? []
            let all = inherited + c.instanceVariables
            let allMeta = inheritedMeta + c.classInstanceVariables
            if Set(all).count != all.count { throw CompileError("\(c.name): an instance variable name twice", file: c.file, line: c.line) }
            if Set(allMeta).count != allMeta.count {
                throw CompileError("\(c.name): a class-side instance variable name twice", file: c.file, line: c.line)
            }
            instanceVariables[c.name] = all
            classInstanceVariables[c.name] = allMeta
            let superKind = c.superclass.flatMap { kinds[$0] } ?? "fixed"
            let kind: String
            switch c.type {
            case nil: kind = ["variable", "bytes", "words16", "words32", "words64"].contains(superKind) ? superKind
                : superKind == "weak" ? "variable" : "fixed"
            case "normal": kind = "fixed"
            case "variable": kind = "variable"
            case "bytes": kind = "bytes"
            case "words": kind = "words32"
            case "words16", "words64", "weak", "ephemeron": kind = c.type!
            default: throw CompileError("\(c.name): unknown #type \(c.type!)", file: c.file, line: c.line)
            }
            kinds[c.name] = kind
            definitions.append(KernelClassDefinition(name: c.name, superclass: c.superclass, instSize: all.count, kind: kind,
                                                     metaSlots: allMeta.count, file: c.file, line: c.line))
        }
        // Methods: the classes', then the extensions'.
        let known = Set(ordered.map(\.name)).union(wellKnown.keys)
        let classNames: @Sendable (String) -> Bool = { known.contains($0) }
        var consumed: Set<String> = []
        var used: [(String, String, Int)] = []  // pragma, file, line
        var all = ordered.flatMap(\.methods)
        for e in extensions {
            guard known.contains(e.name) else { throw CompileError("an extension of unknown class \(e.name)", file: e.file, line: e.line) }
            all += e.methods
        }
        if let st = ordered.first(where: { $0.name == "Smalltalk" }) {
            all.append(TonelMethod(className: "Smalltalk", classSide: true, category: "kernel",
                                   source: Array(kernelDefinitionsSource(ordered, kinds).utf8), line: st.line))
        }
        for m in all {
            let file = (ordered.first { $0.name == m.className } ?? extensions.first { $0.name == m.className })?.file ?? ""
            let ctx = ClassContext(className: m.className, classSide: m.classSide,
                                   instanceVariables: m.classSide ? classInstanceVariables[m.className] ?? []
                                       : instanceVariables[m.className] ?? [],
                                   firstSlot: m.classSide ? Image.classLayoutSize : 0, isClassName: classNames)
            let (am, pragmas) = try compileMethod(m.source, file: file, line: m.line, in: ctx)
            compiled.append(am)
            sources.append("\(m.className)\(m.classSide ? " class" : "")\n\(am.selector)\n" + String(decoding: m.source, as: UTF8.self))
            for p in pragmas {
                if p.selector == "consumesPragmas:", m.classSide, case .array(let xs) = p.arguments[0] {
                    for case .symbol(let s) in xs { consumed.insert(s) }
                }
                used.append((p.selector, file, p.line))
            }
        }
        consumed.insert("consumesPragmas:")
        for (p, file, line) in used where !consumed.contains(p) {
            warnings.append("\(file):\(line): warning: pragma <\(p)> has no consumer (no class declares it in <consumesPragmas:>)")
        }
    }

    func load(into image: Image) throws(CompileError) {
        do {
            try image.defineKernelClasses(definitions)
            try image.installKernelMethods(compiled)
            if image.hasClass("Smalltalk") { try image.setEntryPoint(className: "Smalltalk") }
        } catch {
            throw CompileError(error.message, file: error.file, line: error.line)
        }
    }
}

/// `Smalltalk class >> kernelDefinitions`: per class, its name, superclass,
/// instance variables (its own), class-side instance variables, category
/// and format kind, as a literal Array.
func kernelDefinitionsSource(_ classes: [TonelClass], _ kinds: [String: String]) -> String {
    func sym(_ s: String) -> String { "#" + s }
    func str(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
    var out = "kernelDefinitions\n\t\"Generated by the image build from the class files.\"\n\t^ #(\n"
    for c in classes {
        out += "\t\t(\(sym(c.name)) \(c.superclass.map(sym) ?? "nil") (\(c.instanceVariables.map(sym).joined(separator: " "))) "
        out += "(\(c.classInstanceVariables.map(sym).joined(separator: " "))) \(str(c.category)) \(sym(kinds[c.name] ?? "fixed")))\n"
    }
    return out + "\t)"
}
