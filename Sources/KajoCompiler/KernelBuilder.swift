import Foundation
import KajoVM

/// The image build (module 8b): Tonel files to a verified image. Every
/// class is defined (the well-known ones re-parented as their files say),
/// every method compiled by the bootstrap compiler and verified by the
/// assembler, the entry point is `Smalltalk`, and in a VM before the image
/// is saved: the class definitions are handed to the kernel (`Smalltalk
/// recordDefinitions:`, module 8e: the instance variable names, tag,
/// format kind and comment of every class, which the compiler in Smalltalk
/// and the Tonel writer read; 8b synthesized a method that answered them),
/// the kernel's class-side `initialize` methods run, and every method's
/// source and category are handed over. Any error refuses the whole build.
public struct KernelBuild: Sendable {
    public struct Options: Sendable {
        /// Run `Smalltalk initializeKernel` in a VM before saving.
        public var initialize = true
        /// Module 8d: mark the image a release image (`--release`).
        public var release = false
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

    /// Module 9b: the package a source file belongs to: the name its
    /// package directory's `package.st` gives (`Package { #name : #Foo }`),
    /// else the directory's name with its first letter capitalized
    /// (`kernel/` is `Kernel`). The package directory is the file's
    /// directory, or its parent for a file in a tag's subdirectory (tags as
    /// subdirectories: `kernel/Collections/Array.class.st` is package
    /// `Kernel`, tag `Collections`).
    public static func package(ofFile file: String, tag: String? = nil) -> String {
        var dir = (file as NSString).deletingLastPathComponent
        if tag != nil { dir = (dir as NSString).deletingLastPathComponent }
        if let data = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent("package.st")),
           let text = String(data: data, encoding: .utf8),
           let r = text.range(of: "#name"),
           let colon = text[r.upperBound...].firstIndex(of: ":") {
            let rest = text[text.index(after: colon)...].drop { $0 == " " || $0 == "\t" || $0 == "#" || $0 == "'" }
            let name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" })
            if !name.isEmpty { return name }
        }
        let base = (dir as NSString).lastPathComponent
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    /// The `.st` files of the directories, each directory's by path
    /// relative to it (`package.st`, a package's name, is not a class
    /// file), with their tags: a file at a directory's root has none, a
    /// file in a subdirectory has the subdirectory's name (tags as
    /// subdirectories, one level: a `.st` file further down is refused
    /// naming its path; hidden entries are skipped).
    public static func sources(in directories: [String]) throws(CompileError) -> [(file: String, text: [UInt8], tag: String?)] {
        var out: [(String, [UInt8], String?)] = []
        func isDirectory(_ p: String) -> Bool {
            (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        func read(_ p: String) throws(CompileError) -> [UInt8] {
            guard let data = FileManager.default.contents(atPath: p) else { throw CompileError("cannot read \(p)") }
            return [UInt8](data)
        }
        for d in directories {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: d) else {
                // a single file
                out.append((d, try read(d), nil))
                continue
            }
            var found: [(rel: String, path: String, tag: String?)] = []
            for n in names where !n.hasPrefix(".") {
                let p = (d as NSString).appendingPathComponent(n)
                if isDirectory(p) {
                    guard let inner = try? FileManager.default.contentsOfDirectory(atPath: p) else { throw CompileError("cannot read \(p)") }
                    for m in inner where !m.hasPrefix(".") {
                        let q = (p as NSString).appendingPathComponent(m)
                        if isDirectory(q) {
                            let deeper = (try? FileManager.default.subpathsOfDirectory(atPath: q)) ?? []
                            if let f = deeper.sorted().first(where: { $0.hasSuffix(".st") }) {
                                _ = try tonelTag(ofPath: n + "/" + m + "/" + f)
                            }
                        } else if m.hasSuffix(".st") && m != "package.st" {
                            found.append((n + "/" + m, q, try tonelTag(ofPath: n + "/" + m)))
                        }
                    }
                } else if n.hasSuffix(".st") && n != "package.st" {
                    found.append((n, p, nil))
                }
            }
            for f in found.sorted(by: { $0.rel < $1.rel }) { out.append((f.path, try read(f.path), f.tag)) }
        }
        return out
    }

    /// Build an image from Tonel files at their packages' roots (no tags):
    /// the form the tests' generated files take.
    public static func build(_ files: [(file: String, text: [UInt8])], options: Options = Options()) throws(CompileError) -> Result {
        try build(files.map { ($0.file, $0.text, nil) }, options: options)
    }

    /// Build an image from Tonel sources.
    public static func build(_ files: [(file: String, text: [UInt8], tag: String?)], options: Options = Options()) throws(CompileError) -> Result {
        let plan = try Plan(files)
        let image: Image
        do { image = try Image.bootForKernel(heapMiB: options.heapMiB) } catch { throw CompileError(error.message) }
        defer { image.destroyImage() }
        try plan.load(into: image)
        if options.initialize && image.hasClass("Smalltalk") {
            if let problem = image.runToCompletion(className: "Smalltalk", selector: "recordDefinitions:", strings: plan.definitionRecords) {
                throw CompileError("Smalltalk recordDefinitions: \(problem)")
            }
            if let problem = image.runToCompletion(className: "Smalltalk", selector: "initializeKernel") {
                throw CompileError("Smalltalk initializeKernel: \(problem)")
            }
            // Every method's source and category, kept in the image
            // (Smalltalk sourceOf:, Behavior>>categoryOf:), in Arrays of at
            // most 2000 Strings: "Class[ class]\nselector\ncategory\npackage\nsource"
            // (module 9b: the package when it is not the class's, empty
            // otherwise; an agent's author mark is a pragma in the source).
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
        if options.release { image.seal() }
        let bytes: [UInt8]
        do { bytes = try image.imageBytes() } catch { throw CompileError("saving the image: \(error)") }
        return Result(image: bytes, classes: plan.classes.count, methods: plan.compiled.count, warnings: plan.warnings)
    }
}

/// The classes in definition order, every method compiled, the warnings.
struct Plan {
    var classes: [TonelClass] = []
    /// Tags as subdirectories: each class's tag, from its file's place.
    var tags: [String: String] = [:]
    var definitions: [KernelClassDefinition] = []
    var compiled: [AssembledMethod] = []
    /// "Class[ class]\nselector\ncategory\npackage\nsource" per compiled method.
    var sources: [String] = []
    /// Module 8e: per class, in definition order (superclasses first),
    /// "name\nsuperclass\ninstVars\nclassInstVars\ntag\nkind\npackage\ncomment"
    /// (names separated by blanks; the comment last, it may hold line
    /// breaks; module 9b added the package; the tag, empty for none,
    /// took the category's place with tags as subdirectories).
    var definitionRecords: [String] = []
    var warnings: [String] = []
    /// Instance variable names (inherited first) and class-side ones.
    var instanceVariables: [String: [String]] = [:]
    var classInstanceVariables: [String: [String]] = [:]
    /// Module 8d: per class, every class variable it sees (its own, then
    /// its superclasses'), by name, with the class that declares it.
    var classVariables: [String: [String: String]] = [:]

    init(_ files: [(file: String, text: [UInt8], tag: String?)]) throws(CompileError) {
        var defs: [TonelClass] = []
        var extensions: [TonelClass] = []
        var fileTags: [String: String] = [:]
        for f in files {
            let c = try readTonel(f.text, file: f.file)
            // An extension file stays at its package's root (open question
            // 2): one in a tag's directory is still its package's.
            if c.isExtension { extensions.append(c) } else { defs.append(c) }
            if let t = f.tag { fileTags[f.file] = t }
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
        for c in ordered { if let t = fileTags[c.file] { tags[c.name] = t } }

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
            instanceVariables[c.name] = all
            classInstanceVariables[c.name] = allMeta
            // Module 8d: class variables are capitalized, unique along the
            // chain, and shadow no instance variable of either side (the
            // subclasses' are checked as each comes); module 8e shares the
            // rules with the define-class primitive.
            let inheritedPool = c.superclass.flatMap { classVariables[$0] } ?? [:]
            if let problem = ClassRules.namesProblem(className: c.name, instanceVariables: all, classInstanceVariables: allMeta,
                                                     ownInstanceVariables: c.instanceVariables,
                                                     ownClassInstanceVariables: c.classInstanceVariables,
                                                     classVariables: c.classVariables, inherited: inheritedPool) {
                throw CompileError(problem, file: c.file, line: c.line)
            }
            var visible = inheritedPool
            for v in c.classVariables { visible[v] = c.name }
            classVariables[c.name] = visible
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
            definitionRecords.append([c.name, c.superclass ?? "nil", c.instanceVariables.joined(separator: " "),
                                      c.classInstanceVariables.joined(separator: " "), tags[c.name] ?? "", kind,
                                      KernelBuild.package(ofFile: c.file, tag: tags[c.name]), c.comment]
                .joined(separator: "\n"))
            definitions.append(KernelClassDefinition(name: c.name, superclass: c.superclass, instSize: all.count, kind: kind,
                                                     metaSlots: allMeta.count, classVariables: c.classVariables, file: c.file,
                                                     line: c.line))
        }
        // Methods: the classes', then the extensions'.
        let known = Set(ordered.map(\.name)).union(wellKnown.keys)
        let classNames: @Sendable (String) -> Bool = { known.contains($0) }
        let pools = classVariables
        var consumed: Set<String> = []
        var used: [(String, String, Int)] = []  // pragma, file, line
        // Module 9b: each method with the package of the file it came from.
        var all = ordered.flatMap { c in c.methods.map { ($0, c.file, "") } }
        var classPackage: [String: String] = [:]
        for c in ordered { classPackage[c.name] = KernelBuild.package(ofFile: c.file, tag: tags[c.name]) }
        for e in extensions {
            guard known.contains(e.name) else { throw CompileError("an extension of unknown class \(e.name)", file: e.file, line: e.line) }
            let p = KernelBuild.package(ofFile: e.file, tag: fileTags[e.file])
            all += e.methods.map { ($0, e.file, p == classPackage[e.name] ? "" : p) }
        }
        for (m, file, package) in all {
            let ctx = ClassContext(className: m.className, classSide: m.classSide,
                                   instanceVariables: m.classSide ? classInstanceVariables[m.className] ?? []
                                       : instanceVariables[m.className] ?? [],
                                   firstSlot: m.classSide ? Image.classLayoutSize : 0, isClassName: classNames,
                                   classVariables: pools[m.className] ?? [:])
            let (am, pragmas) = try compileMethod(m.source, file: file, line: m.line, in: ctx)
            compiled.append(am)
            sources.append("\(m.className)\(m.classSide ? " class" : "")\n\(am.selector)\n\(m.category)\n\(package)\n"
                           + String(decoding: m.source, as: UTF8.self))
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
