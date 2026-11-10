// The review fixes, part 2, items 6 and 7 (kernel.F15, kernel.F16): the
// kernel's compiler beside the bootstrap's. A probe holds a kernel image
// and an interpreter of no VM (as the make-and-run mode does), and for one
// source compares the bootstrap's outcome (an AssembledMethod, or nil for
// a refusal) with the kernel compiler's (`Compiler class>>compare:in:with:`,
// which compiles with the Smalltalk compiler, has the VM make the method,
// and compares the two CompiledCodes in their plain form). The syntax
// fuzzer's kernel mode and the compilers' corpus test use it.

/// A kernel image and an interpreter that compile with the kernel's
/// compiler. One per thread; not Sendable.
package final class KernelCompilerProbe {
    let image: Image
    let interp: Interpreter
    let stack: Stack
    let compilerClass: Oop
    let targetClass: Oop
    let codeClass: UInt64

    /// A probe over the kernel image `bytes` whose methods are compiled in
    /// the class `className`. The Smalltalk compiler runs on a stack of
    /// `stackWords` words (a Process's limit by default: `VMConfig`'s
    /// `maxStackWords`).
    package init(image bytes: [UInt8], className: String, stackWords: Int = VMConfig().maxStackWords) throws {
        image = try Image.load(image: bytes)
        guard let compiler = image.classIndex(named: "Compiler"), let target = image.classIndex(named: className),
              let code = image.classIndex(named: "CompiledCode") else {
            image.destroy()
            throw LoadError(.unknownClass, "the kernel image has no Compiler, CompiledCode or \(className)")
        }
        compilerClass = image.om.classOop(compiler)
        targetClass = image.om.classOop(target)
        codeClass = code
        interp = Interpreter(image: image)
        stack = Stack(words: stackWords)
    }

    deinit {
        stack.destroy()
        interp.destroy()
        image.destroy()
    }

    /// Whether `name` names a class of the image (the bootstrap's
    /// ClassContext asks this).
    package func isClassName(_ name: String) -> Bool { image.classIndex(named: name) != nil }

    /// Every class name of the image.
    package var classNames: Set<String> { image.classNames }

    /// nil when the two compilers agree on `source` (both refuse, or both
    /// accept with the same plain bytecodes, literals and header), else
    /// the disagreement. `bootstrap` is the bootstrap's method, nil when it
    /// refused the source.
    package func compare(_ source: [UInt8], bootstrap: AssembledMethod?) -> String? {
        // A String in the image is valid UTF-8 (every path that makes one
        // validates, the protocol's reader too): the kernel's compiler is
        // never handed other bytes, so they are the bootstrap's alone.
        guard String(validating: source, as: UTF8.self) != nil else {
            return bootstrap == nil ? nil : "the bootstrap accepted bytes that are not UTF-8"
        }
        var handles: [RootHandle] = []
        defer { for h in handles { image.om.removeRoot(h) } }
        guard let text = try? image.allocateBytes(WellKnown.string, source, roots: []) else { return "the probe could not allocate the source" }
        handles.append(image.om.addRoot(text))
        var theirs = image.nilObject
        if let m = bootstrap {
            do {
                let (c, h) = try image.codeObject(m, codeClass: codeClass)
                handles.append(h)
                theirs = c
            } catch {
                return "the probe could not build the bootstrap's code: \(error)"
            }
        }
        let r = interp.run(on: stack, receiver: compilerClass, selector: "compare:in:with:", arguments: [text, targetClass, theirs])
        image.om.retireAllContexts()
        switch r {
        case .failure(let e): return "the kernel compiler ended in a VMError: \(e)"
        case .success(let v):
            if v == image.nilObject { return nil }
            guard v.isObject, image.om.classIndex(of: v) == WellKnown.string else { return "the comparison answered neither nil nor a String" }
            let n = Int(image.om.count(of: v))
            return String(decoding: (0..<n).map { image.om.loadByte(v, $0) }, as: UTF8.self)
        }
    }
}
