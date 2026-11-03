// The kasm loader's rejection of every malformed v1 construct (bytecode
// set v1, blocks, pragmas, literals, class formats, metaclasses), and the
// shapes it builds: block methods, pragma literals, class formats.

import Testing
@testable import KajoVM

private func load(_ src: String) -> LoadError.Kind? {
    guard let img = try? makeImage() else { return .heapFull }
    defer { img.destroy() }
    do {
        try img.load([(file: "t.kasm", text: src)])
        return nil
    } catch {
        return error.kind
    }
}

private func m(_ body: String, temps: Int = 0, header: String = "method Object m") -> String {
    "\(header) temps=\(temps)\n\(body)\nend\n"
}

@Test(arguments: [
    // returns in the wrong kind of body
    (m(" push_nil\n block_return"), LoadError.Kind.badOperand),
    (m(" push_nil\n nonlocal_return"), .badOperand),
    (m(" push_closure b 0\n return_top\nblock b args=0 copied=0 temps=0\n push_nil\n return_top"), .badOperand),
    // blocks: unknown, wrong copied count, made twice, never made, itself
    (m(" push_closure zz 0\n return_top"), .badOperand),
    (m(" push_nil\n push_closure b 0\n return_top\nblock b args=0 copied=1 temps=0\n push_nil\n block_return"), .badOperand),
    (m(" push_closure b 0\n push_closure b 0\n pop\n return_top\nblock b args=0 copied=0 temps=0\n push_nil\n block_return"), .badOperand),
    (m(" push_nil\n return_top\nblock b args=0 copied=0 temps=0\n push_nil\n block_return"), .badOperand),
    (m(" push_closure b 0\n return_top\nblock b args=0 copied=0 temps=0\n push_closure b 0\n block_return"), .badOperand),
    (m(" push_closure b 0\n return_top\nblock b args=0 copied=0 temps=0\n push_closure c 0\n block_return\nblock c args=0 copied=0 temps=0\n push_closure b 0\n block_return"), .badOperand),
    // a block's temps: args + copied + temps, never its closure word
    (m(" push_closure b 0\n return_top\nblock b args=1 copied=0 temps=1\n push_temp 2\n block_return"), .badOperand),
    (m(" push_closure b 0\n return_top\nblock b args=0 copied=0 temps=0\n block_return"), .badStack),
    (m(" push_closure b 0\n return_top\nblock b args=0 copied=0 temps=0"), .emptyMethod),
    (m(" push_closure b 0\n return_top\nblock b args=x copied=0 temps=0\n push_nil\n block_return"), .badOperand),
    (m(" push_closure b 0\n return_top\nblock b args=0 copied=0 temps=0\n push_nil\n block_return\nblock b args=0 copied=0 temps=0\n push_nil\n block_return"), .duplicateLabel),
    // the prefix is the assembler's, operands in range
    (m(" ext 1\n push_lit 1\n return_top"), .unknownOpcode),
    (m(" push_new_array 4096\n return_top"), .badOperand),
    (m(" push_tv_slot 0 3\n return_top", temps: 1), .badOperand),
    (m(" store_tv_slot 4095 0\n push_nil\n return_top", temps: 1), .badOperand),
    (m(" push_self\n send_super foo: 0\n return_top"), .badOperand),
    (m(" push_self\n at_put\n return_top"), .badStack),
    (m(" value2\n return_top"), .badStack),
    // pragmas
    (m(" push_nil\n return_top\n pragma foo:"), .syntax),
    ("method Object m temps=0\n pragma foo: 1 2\n push_nil\n return_top\nend\n", .badOperand),
    ("method Object m temps=0\n pragma foo: &&\n push_nil\n return_top\nend\n", .badOperand),
    ("method Object m temps=0\n pragma 3\n push_nil\n return_top\nend\n", .syntax),
    // literals
    (m(" push_lit 'open\n return_top"), .syntax),
    (m(" push_lit $U+D800\n return_top"), .badOperand),
    (m(" push_lit 1e999\n return_top"), .badOperand),
    (m(" push_lit $\n return_top"), .badOperand),
    // class formats and metaclasses
    ("class A Object 1 bytes\n", .badOperand),
    ("class A Object 0 ephemeron\n", .badOperand),
    ("class A Object 0 sideways\n", .syntax),
    ("class A Object 0 weak bytes\n", .syntax),
    ("class A ByteArray 1\n", .badClass),
    ("class A CompiledMethod 0\n", .badClass),
    ("class A Object 0 meta=1\nclass B A 0\n", .badClass),
    ("class A Object 0\nmethod A class m temps=0\n push_ivar 0\n return_top\nend\n", .badClass),
    ("class A Object 0 meta=1\nmethod A class m temps=0\n push_ivar 6\n return_top\nend\n", .badClass),
    ("method Context m temps=0\n push_ivar 0\n return_top\nend\n", .badClass),
    ("method BlockClosure m temps=0\n push_ivar 0\n return_top\nend\n", .badClass),
    ("method Object class class m temps=0\n push_nil\n return_top\nend\n", .syntax),
] as [(String, LoadError.Kind)])
func theLoaderRejectsMalformedV1Constructs(_ src: String, _ kind: LoadError.Kind) {
    #expect(load(src) == kind, "\(src)")
}

@Test func theLoaderAcceptsTheV1Shapes() throws {
    let img = try makeImage()
    defer { img.destroy() }
    try img.load([(file: "t.kasm", text: """
    class W Object 0 words32
    class F Object 2 fixed meta=1
    method F class count temps=0
      push_ivar 5
      return_top
    end
    method F m: temps=1
      pragma primitive:error: 7 #code
      pragma tag
      push_temp 0
      push_closure outer 1
      return_top
    block outer args=0 copied=1 temps=1
      push_temp 0
      push_closure inner 1
      block_return
    block inner args=1 copied=1 temps=0
      push_temp 1
      nonlocal_return
    end
    """)])
    let om = img.om
    let w = try #require(img.classIndex(named: "W")), f = try #require(img.classIndex(named: "F"))
    #expect(om.classFormat(w).kind == .words32 && om.classFormat(f).kind == .fixed && om.classFormat(f).namedSlots == 2)
    #expect(om.classFormat(img.metaclassIndex(of: f)).namedSlots == ClassLayout.size + 1)
    let meth = try #require(img.lookup(f, img.symbol("m:")!))
    let lits = om.load(meth, MethodLayout.literals)
    let outer = om.load(lits, 0)
    #expect(om.classIndex(of: outer) == WellKnown.method)
    #expect(om.load(outer, MethodLayout.flags) == Oop(smallInteger: MethodFlags.block | MethodFlags.needsHome))
    #expect(om.load(outer, MethodLayout.temps) == Oop(smallInteger: 1 + 1 + 1))  // copied + temp + closure word
    #expect(om.load(outer, MethodLayout.methodClass) == om.classOop(f) && om.load(outer, MethodLayout.selector) == img.nilObject)
    let pragmas = (0..<Int(om.count(of: lits))).map { om.load(lits, $0) }.filter { $0.isObject && om.classIndex(of: $0) == WellKnown.pragma }
    #expect(pragmas.count == 2)
    let p = pragmas[0]
    #expect(img.symbolName(om.load(p, PragmaLayout.selector)) == "primitive:error:" && om.load(p, PragmaLayout.method) == meth)
    let args = om.load(p, PragmaLayout.arguments)
    #expect(om.load(args, 0) == Oop(smallInteger: 7) && om.load(args, 1) == img.symbol("code")!)
    #expect(om.isReadOnly(p) && om.isReadOnly(args))
    // the heap verifier accepts what the loader built
    #expect(verifyHeapMethod(om, meth, classIndex: f, nilObject: img.nilObject) == nil)
}
