import KajoVM

/// The syntax fuzz target's entry (`just fuzz syntax <seconds>`): bytes as
/// a Tonel class file when they start like one, else as a method's source,
/// through the reader, the parser, the analysis, code generation, the
/// assembler and the bytecode verifier. Every input must end in a
/// CompileError or a verified method, never a trap. Answers whether it
/// compiled.
public enum FuzzSyntax {
    static let context = ClassContext(className: "Object", classSide: false, instanceVariables: ["a", "b"],
                                      isClassName: { $0.first?.isUppercase == true })

    @discardableResult
    public static func run(_ bytes: [UInt8]) -> Bool {
        let prefix = String(decoding: bytes.prefix(16), as: UTF8.self)
        if prefix.hasPrefix("Class") || prefix.hasPrefix("Extension") || prefix.hasPrefix("\"") {
            guard let c = try? readTonel(bytes, file: "fuzz.st") else { return false }
            var ok = true
            for m in c.methods.prefix(64) {
                let ctx = ClassContext(className: "Object", classSide: m.classSide, instanceVariables: c.instanceVariables,
                                       isClassName: context.isClassName)
                ok = (try? compileMethod(m.source, file: "fuzz.st", line: m.line, in: ctx)) != nil && ok
            }
            return ok
        }
        return (try? compileMethod(bytes, file: "fuzz", in: context)) != nil
    }
}
