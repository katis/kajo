import Testing
@testable import KajoVM

private func method(_ body: String, header: String = "method Object m temps=0") -> String {
    "\(header)\n\(body)\nend\n"
}

private func assembleOne(_ src: String) throws(LoadError) -> AssembledMethod {
    let f = try parseKasm(src, file: "t.kasm")
    #expect(f.methods.count == 1)
    return try assemble(f.methods[0])
}

private func rejection(_ src: String) -> LoadError.Kind? {
    do {
        let f = try parseKasm(src, file: "t.kasm")
        for m in f.methods { _ = try assemble(m) }
        return nil
    } catch {
        return error.kind
    }
}

// MARK: - opcode table

@Test func theOpcodeTableIsContiguous() {
    // bytecode set v1: v0's 27 opcodes unchanged, then ADR 0009's, then
    // (interpreter speed) the 17 fused opcodes from 50 (the count was 50).
    #expect(Opcode.allCases.count == 67)
    for (i, op) in Opcode.allCases.enumerated() { #expect(Int(op.rawValue) == i && Opcode.decode(UInt8(i)) == op) }
    for b in 67...255 { #expect(Opcode.decode(UInt8(b)) == nil) }
    #expect(Opcode.allCases.filter { $0.fusedParts != nil }.map(\.rawValue) == Array(50...66))
    #expect(Opcode.send.rawValue == 0x0C && Opcode.jump.rawValue == 0x0F && Opcode.identical.rawValue == 0x1A)
    #expect(Opcode(mnemonic: "push_temp") == .pushTemp && Opcode(mnemonic: "jump_if_false") == .jumpIfFalse)
    #expect(Opcode.send.length == 3 && Opcode.jump.length == 3 && Opcode.pushInt.length == 2 && Opcode.add.length == 1)
    #expect(Opcode.add.specialSelector == "+" && Opcode.eq.specialSelector == "=" && Opcode.pop.specialSelector == nil)
    #expect(Array(specialSelectorNames.prefix(9)) == ["+", "-", "*", "<", ">", "<=", ">=", "=", "=="])
    #expect(specialSelectorNames.count == 23)
    for op in Opcode.allCases where op.specialSelector != nil {
        #expect(specialSelectorNames[op.specialIndex] == op.specialSelector && arity(of: op.specialSelector!) == op.specialArgc)
    }
}

@Test func selectorArity() {
    #expect(arity(of: "fib") == 0)
    #expect(arity(of: "+") == 1 && arity(of: "\\\\") == 1 && arity(of: "<=") == 1)
    #expect(arity(of: "at:put:") == 2 && arity(of: "run:of:") == 2 && arity(of: "x:") == 1)
}

// MARK: - assembling

/// Ported from object-representation: every fixture kernel parses and
/// assembles (and passes the stack-depth verifier).
@Test func kernelsAssemble() throws {
    for name in ["prelude", "lib"] + goldenKernels.map(\.name) {
        let f = try parseKasm(kernel(name), file: name)
        #expect(!f.methods.isEmpty)
        for m in f.methods { _ = try assemble(m) }
    }
}

@Test func theAssemblerEncodesOperandsAndLiterals() throws {
    let m = try assembleOne("""
    method UndefinedObject run:of: temps=1
      push_lit 1000
      push_lit #foo
      push_lit 1000
      push_lit @Array
      push_int -3
      send foo:bar: 2
    top:
      dup
      jump_if_true top
      store_temp 2
      push_lit nil
      return_top
    end
    """)
    #expect(m.selector == "run:of:" && m.argc == 2 && m.temps == 1 && m.primitive == 0)
    #expect(m.literals == [.integer(1000), .symbol("foo"), .classRef("Array"), .symbol("foo:bar:"), .nilObject])
    let b: [UInt8] = [
        0x01, 0, 0x01, 1, 0x01, 0, 0x01, 2, 0x0B, 0xFD, 0x0C, 3, 2,
        0x07,                 // top: (offset 13)
        0x10, 0xFC, 0xFF,     // jump_if_true top: 13 - 17 = -4
        0x04, 2, 0x01, 4, 0x0D,
    ]
    #expect(m.bytecodes == b)
    #expect(m.maxStack == 5)
}

@Test func forwardJumpsAndUnreachableCode() throws {
    let m = try assembleOne(method("""
      push_true
      jump_if_false a
      push_int 1
      return_top
    a:
      push_int 2
      jump b
      pop
    b:
      return_top
    """))
    #expect(m.bytecodes == [0x09, 0x11, 3, 0, 0x0B, 1, 0x0D, 0x0B, 2, 0x0F, 1, 0, 0x06, 0x0D])
    #expect(m.maxStack == 1)
}

@Test func aPrimitiveMethodMayHaveABody() throws {
    let bare = try assembleOne("method Object at: temps=0 prim=1\nend\n")
    #expect(bare.primitive == 1 && bare.bytecodes.isEmpty && bare.argc == 1)
    let withBody = try assembleOne("method Object at: temps=0 prim=1\n  push_int 0\n  return_top\nend\n")
    #expect(withBody.primitive == 1 && withBody.bytecodes == [0x0B, 0, 0x0D])
}

// MARK: - malformed input: each class is an error value, never a trap

@Test(arguments: [
    // operands
    ("push_int 128\nreturn_top", LoadError.Kind.badOperand),
    ("push_int -129\nreturn_top", .badOperand),
    ("push_int x\nreturn_top", .badOperand),
    ("push_temp 0\nreturn_top", .badOperand),                       // no temps
    ("push_ivar 4095\nreturn_top", .badOperand),
    ("push_lit 99999x\nreturn_top", .badOperand),
    ("push_lit 1.5.2\nreturn_top", .badOperand),
    ("push_lit &x\nreturn_top", .badOperand),
    ("push_lit\nreturn_top", .badOperand),
    ("pop 1\nreturn_self", .badOperand),
    ("push_self\nsend foo: 2\nreturn_top", .badOperand),            // argc does not match
    ("push_self\nsend foo\nreturn_top", .badOperand),
    ("push_self\nsend foo 0 0\nreturn_top", .badOperand),
    // opcodes and labels
    ("frobnicate\nreturn_self", .unknownOpcode),
    ("jump nowhere\nreturn_self", .unknownLabel),
    ("a:\na:\nreturn_self", .duplicateLabel),
    // the stack-depth verifier
    ("pop\nreturn_self", .badStack),                                // underflow
    ("return_top", .badStack),
    ("push_self\nsend at:put: 2\nreturn_top", .badStack),
    ("push_true\njump_if_true a\npush_int 1\na:\nreturn_self", .badStack), // depths 0 and 1 meet at a
    ("push_int 1", .badStack),                                      // falls off the end
    ("l:\npush_int 1\njump l", .badStack),                          // grows on every iteration
    ("", .emptyMethod),
] as [(String, LoadError.Kind)])
func theAssemblerRejects(_ body: String, _ kind: LoadError.Kind) {
    #expect(rejection(method(body)) == kind, "\(body)")
}

@Test(arguments: [
    ("method Object m temps=0 prim=0\nreturn_self\nend\n", LoadError.Kind.badOperand),
    ("method Object m temps=0 prim=256\nend\n", .badOperand),
    ("method Object m temps=-1\nreturn_self\nend\n", .badOperand),
    ("method Object m temps=300\nreturn_self\nend\n", .badOperand),
    ("method Object m\nreturn_self\nend\n", .syntax),
    ("method Object m temps=0 frob=1\nreturn_self\nend\n", .syntax),
    ("method Object m temps=0\nreturn_self\n", .syntax),            // no end
    ("return_self\n", .syntax),                                    // outside a method
    ("end\n", .syntax),
    ("class A\n", .syntax),
    ("class A Object x\n", .badOperand),
    ("class A Object 4096\n", .badOperand),
    ("class 9A Object 0\n", .syntax),
    ("method Object m temps=0\nclass A Object 0\nend\n", .syntax),
] as [(String, LoadError.Kind)])
func theParserRejects(_ src: String, _ kind: LoadError.Kind) {
    #expect(rejection(src) == kind, "\(src)")
}

@Test func oversizeMethodsAreRejected() {
    // 11 000 x 3 bytes: over the 32 760 bytes of a block's byte object
    let body = String(repeating: "push_int 1\npop\n", count: 11000) + "push_self\nreturn_top"
    #expect(rejection(method(body)) == .methodTooLarge)
    let under = String(repeating: "push_int 1\npop\n", count: 5000) + "return_self"
    #expect(rejection(method(under)) == nil)
}

@Test func tooManyLiteralsAreRejected() {
    // Module 8: two-byte literal indices with the ext prefix, up to the
    // literal Array's block-sized limit.
    let n = LoaderLimits().maxLiterals
    let body = (0...n).map { "push_lit \($0 + 1000)\npop" }.joined(separator: "\n") + "\nreturn_self"
    #expect(rejection(method(body)) == .tooManyLiterals)
    let ok = (0..<n).map { "push_lit \($0 + 1000)\npop" }.joined(separator: "\n") + "\nreturn_self"
    #expect(rejection(method(ok)) == nil)
}

@Test func errorsNameTheFileAndLine() {
    do {
        _ = try assemble(try parseKasm("; c\nmethod Object m temps=0\n  push_int 1\n  frob\nend\n", file: "x.kasm").methods[0])
        Issue.record("accepted")
    } catch {
        #expect(error.file == "x.kasm" && error.line == 4)
        #expect("\(error)".contains("x.kasm:4"))
    }
}
