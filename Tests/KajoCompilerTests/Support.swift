import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoVM

/// A class file in Tonel from a header and methods (`Foo >> bar [ ... ]`).
func tonel(_ name: String, _ superclass: String? = "Object", ivars: [String] = [], classIvars: [String] = [], classVars: [String] = [],
           type: String? = nil, _ methods: String) -> (file: String, text: [UInt8]) {
    var keys = ["#name : #\(name)", "#superclass : \(superclass.map { "#" + $0 } ?? "nil")",
                "#instVars : [ \(ivars.map { "'\($0)'" }.joined(separator: ", ")) ]",
                "#classInstVars : [ \(classIvars.map { "'\($0)'" }.joined(separator: ", ")) ]"]
    if !classVars.isEmpty { keys.append("#classVars : [ \(classVars.map { "'\($0)'" }.joined(separator: ", ")) ]") }
    if let type { keys.append("#type : #\(type)") }
    let s = "Class {\n\t" + keys.joined(separator: ",\n\t") + "\n}\n\n" + methods
    return ("\(name).class.st", Array(s.utf8))
}

/// The smallest class set a compiled method can run on: the well-known
/// classes' primitives that the tests below use.
let miniKernel: [(file: String, text: [UInt8])] = [
    tonel("Object", nil, """
    Object >> == other [ <primitive: 18> ]
    Object >> class [ <primitive: 5> ]
    Object >> at: i [ <primitive: 1> ^ nil ]
    Object >> at: i put: v [ <primitive: 2> ^ nil ]
    Object >> yourself [ ^ self ]
    Object >> value [ ^ self ]
    Object >> isNil [ ^ false ]
    """),
    tonel("Behavior", "Object", ivars: ["superclass", "methodDict", "name", "instSize", "classIndex"], """
    Behavior >> new [ <primitive: 4> ^ nil ]
    Behavior >> new: n [ <primitive: 3> ^ nil ]
    Behavior >> basicNew [ <primitive: 4> ^ nil ]
    """),
    tonel("ClassDescription", "Behavior", ""),
    tonel("Class", "ClassDescription", ""),
    tonel("Metaclass", "ClassDescription", ivars: ["thisClass", "classPool"], ""),
    tonel("SmallInteger", "Object", """
    SmallInteger >> + n [ <primitive: 40> ^ nil ]
    SmallInteger >> - n [ <primitive: 41> ^ nil ]
    SmallInteger >> * n [ <primitive: 42> ^ nil ]
    SmallInteger >> < n [ <primitive: 48> ^ nil ]
    SmallInteger >> > n [ <primitive: 49> ^ nil ]
    SmallInteger >> <= n [ <primitive: 50> ^ nil ]
    SmallInteger >> >= n [ <primitive: 51> ^ nil ]
    SmallInteger >> = n [ <primitive: 52> ^ nil ]
    SmallInteger >> \\\\ n [ <primitive: 45> ^ nil ]
    SmallInteger >> // n [ <primitive: 44> ^ nil ]
    """),
    tonel("BlockClosure", "Object", ivars: ["method", "receiver", "home"], type: "variable", """
    BlockClosure >> value [ <primitive: 80> ^ nil ]
    BlockClosure >> value: a [ <primitive: 81> ^ nil ]
    BlockClosure >> value: a value: b [ <primitive: 82> ^ nil ]
    """),
    tonel("Array", "Object", type: "variable", """
    Array >> size [ <primitive: 95> ^ 0 ]
    Array >> do: aBlock [ 1 to: self size do: [:i | aBlock value: (self at: i)] ]
    Array >> inject: acc into: aBlock [ | r | r := acc. self do: [:e | r := aBlock value: r value: e]. ^ r ]
    """),
]

/// Build an image from `files` (no kernel initialization) and run
/// `className selector` on the class side to completion: the answer as a
/// SmallInteger, or the failure.
func runClassSide(_ files: [(file: String, text: [UInt8])], _ className: String, _ selector: String) throws -> Int64 {
    var o = KernelBuild.Options()
    o.initialize = false
    o.heapMiB = 64
    let r = try KernelBuild.build(files, options: o)
    let image = try Image.load(image: r.image)
    defer { image.destroy() }
    var vc = VMConfig()
    vc.backgroundWorkers = 1
    vc.nursery.bytes = 0
    vc.marking.enabled = false
    vc.relocation.enabled = false
    vc.young.mode = .stw
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

enum RunError: Error { case noMethod, vm(String), notAnInteger(String) }

/// Compile one method in a class with the given instance variables.
func compile(_ source: String, in className: String = "Object", ivars: [String] = [], classSide: Bool = false) throws -> AssembledMethod {
    let ctx = ClassContext(className: className, classSide: classSide, instanceVariables: ivars,
                           isClassName: { ["Object", "Array", "SmallInteger"].contains($0) })
    return try compileMethod(Array(source.utf8), file: "test", in: ctx).0
}

/// The method's instructions as kasm-like text, one per line.
func listing(_ m: AssembledMethod) -> [String] {
    var out: [String] = []
    var off = 0
    while off < m.bytecodes.count, let d = decodeInstruction(m.bytecodes, at: off) {
        var s = d.op.mnemonic
        switch d.op.operands {
        case .none, .prefix: break
        case .index, .int8: s += " \(d.a)"
        case .jump: s += " \(d.a)"
        case .send: s += " \(m.literals[d.a]) \(d.b)"
        case .closure, .vectorSlot: s += " \(d.a) \(d.b)"
        }
        if d.op == .pushLiteral { s = "push_lit \(m.literals[d.a])" }
        out.append(s)
        off += d.length
    }
    return out
}

/// The Tonel files of a package directory, relative to it and sorted: its
/// own and those one directory down, in its tags' subdirectories (tags as
/// subdirectories); `package.st` is not one.
func tonelFiles(in directory: String) throws -> [String] {
    var out: [String] = []
    for n in try FileManager.default.contentsOfDirectory(atPath: directory) where !n.hasPrefix(".") {
        let p = (directory as NSString).appendingPathComponent(n)
        if let inner = try? FileManager.default.contentsOfDirectory(atPath: p) {
            out += inner.filter { $0.hasSuffix(".st") }.map { n + "/" + $0 }
        } else if n.hasSuffix(".st") && n != "package.st" {
            out.append(n)
        }
    }
    return out.sorted()
}
