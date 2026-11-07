import Testing
@testable import KajoVM

// Interpreter speed, part 2: fused instructions (docs/modules/interpreter-speed.md).
// Every fused opcode runs its fast path and its fallback, fused and plain
// (the `noFusion` switch), with the same answers; the peephole changes
// first bytes only and is idempotent; the verifier refuses a fused opcode
// without its second part.

/// The bytecodes of `UndefinedObject>>run:of:` as made.
private func runOfBytes(_ h: Harness) throws -> [UInt8] {
    let m = try #require(h.image.lookup(WellKnown.undefinedObject, h.image.symbol("run:of:")!))
    return h.om.bytes(of: h.om.load(m, MethodLayout.bytecodes))
}

/// One program per fused opcode: (the fused opcode it must contain, the
/// method body, temps, the answer). Each runs the fast path and, where
/// there is one, the fallback (a LargeInteger, a Float, a non-integer).
private let programs: [(Opcode, String, Int, Int64)] = [
    (.pushTempPushTemp, "push_int 3\n store_temp 2\n push_int 4\n store_temp 3\n push_temp 2\n push_temp 3\n sub\n return_top", 2, -1),
    (.pushTempPushInt, "push_int 9\n store_temp 2\n push_temp 2\n push_int 5\n sub\n return_top", 1, 4),
    (.pushSelfPushTemp, "push_self\n push_temp 0\n pop\n pop\n push_int 7\n return_top", 0, 7),
    (.pushSelfPushInt, "push_self\n push_int 2\n pop\n pop\n push_int 8\n return_top", 0, 8),
    // Fast, then the overflow into a LargeInteger and back (the fallback
    // is the push alone: the plain `add` makes the LargeInteger).
    (.pushIntAdd, "push_temp 0\n push_int 100\n add\n push_lit 4611686018427387903\n push_int 1\n add\n push_lit 4611686018427387903\n sub\n add\n return_top", 0, 101),
    (.pushIntSub, "push_temp 0\n push_int 7\n sub\n push_lit -4611686018427387904\n push_int 1\n sub\n push_lit -4611686018427387904\n sub\n add\n return_top", 0, -8),
    (.addStoreTemp, "push_int 5\n store_temp 2\n push_int 6\n store_temp 3\n push_temp 2\n push_temp 3\n add\n store_temp 2\n push_lit 4611686018427387903\n store_temp 3\n push_temp 3\n push_temp 2\n add\n store_temp 3\n push_temp 3\n push_lit 4611686018427387903\n sub\n return_top", 2, 11),
    (.subStoreTemp, "push_int 6\n store_temp 2\n push_int 5\n store_temp 3\n push_temp 2\n push_temp 3\n sub\n store_temp 2\n push_lit -4611686018427387904\n store_temp 3\n push_temp 3\n push_temp 2\n sub\n store_temp 3\n push_temp 3\n push_lit -4611686018427387904\n sub\n return_top", 2, -1),
    // A loop: the backward jump polls.
    (.storeTempJump, "push_int 0\n store_temp 2\nloop:\n push_temp 2\n push_int 100\n lt\n jump_if_false done\n push_temp 2\n push_int 1\n add\n push_int 0\n add\n store_temp 2\n jump loop\ndone:\n push_temp 2\n return_top", 1, 100),
    (.dupStoreTemp, "push_int 6\n dup\n store_temp 2\n push_temp 2\n add\n return_top", 1, 12),
    (.popPushTemp, "push_int 6\n store_temp 2\n push_int 1\n pop\n push_temp 2\n return_top", 1, 6),
    // Both outcomes, and a Float operand (the fallback: a special send's tier).
    (.ltJumpIfFalse, "push_int 1\n push_int 2\n lt\n jump_if_false bad\n push_int 2\n push_int 1\n lt\n jump_if_false ok\nbad:\n push_int 0\n return_top\nok:\n push_lit 1.5\n push_int 2\n lt\n jump_if_false bad\n push_int 1\n return_top", 0, 1),
    (.gtJumpIfFalse, "push_int 2\n push_int 1\n gt\n jump_if_false bad\n push_int 1\n push_int 2\n gt\n jump_if_false ok\nbad:\n push_int 0\n return_top\nok:\n push_lit 2.5\n push_int 2\n gt\n jump_if_false bad\n push_int 1\n return_top", 0, 1),
    (.leJumpIfFalse, "push_int 2\n push_int 2\n le\n jump_if_false bad\n push_int 3\n push_int 2\n le\n jump_if_false ok\nbad:\n push_int 0\n return_top\nok:\n push_lit 1.5\n push_int 2\n le\n jump_if_false bad\n push_int 1\n return_top", 0, 1),
    (.geJumpIfFalse, "push_int 2\n push_int 2\n ge\n jump_if_false bad\n push_int 1\n push_int 2\n ge\n jump_if_false ok\nbad:\n push_int 0\n return_top\nok:\n push_lit 2.5\n push_int 2\n ge\n jump_if_false bad\n push_int 1\n return_top", 0, 1),
    (.eqJumpIfFalse, "push_int 2\n push_int 2\n eq\n jump_if_false bad\n push_int 1\n push_int 2\n eq\n jump_if_false ok\nbad:\n push_int 0\n return_top\nok:\n push_lit 2.0\n push_int 2\n eq\n jump_if_false bad\n push_int 1\n return_top", 0, 1),
    (.identicalJumpIfFalse, "push_nil\n push_nil\n identical\n jump_if_false bad\n push_true\n push_nil\n identical\n jump_if_false ok\nbad:\n push_int 0\n return_top\nok:\n push_int 1\n return_top", 0, 1),
]

@Test(arguments: programs.indices)
func fusedInstructionsAnswerAsThePlainOnes(_ k: Int) throws {
    let (op, body, temps, expected) = programs[k]
    let fused = try Harness(runOf(body, temps: temps))
    defer { fused.destroy() }
    var off = TestSwitches()
    off.noFusion = true
    let plain = try Harness(runOf(body, temps: temps), switches: off)
    defer { plain.destroy() }
    #expect(try fused.value() == expected)
    #expect(try plain.value() == expected)
    let fb = try runOfBytes(fused), pb = try runOfBytes(plain)
    #expect(fb.contains(op.rawValue), "\(op.mnemonic) was not fused")
    #expect(!pb.contains(where: { Opcode.decode($0)?.fusedParts != nil }))
    // Only first bytes differ, each from its plain first part.
    #expect(fb.count == pb.count)
    for i in fb.indices where fb[i] != pb[i] {
        #expect(Opcode.decode(fb[i])?.fusedParts?.0.rawValue == pb[i])
    }
}

/// The peephole: first bytes only, left to right, idempotent; an extended
/// instruction is never fused; bytes that do not decode are left alone.
@Test func thePeepholeRewritesFirstBytesOnly() {
    let p = Opcode.pushTemp.rawValue, i = Opcode.pushInt.rawValue, a = Opcode.add.rawValue, st = Opcode.storeTemp.rawValue
    let plain: [UInt8] = [p, 2, i, 1, a, st, 2, Opcode.returnSelf.rawValue]
    let fused = fuseBytecodes(plain)
    #expect(fused == [Opcode.pushTempPushInt.rawValue, 2, i, 1, Opcode.addStoreTemp.rawValue, st, 2, Opcode.returnSelf.rawValue])
    #expect(fuseBytecodes(fused) == fused)
    // push_temp push_temp push_temp: the first two, the third alone.
    let three: [UInt8] = [p, 0, p, 1, p, 2, Opcode.returnTop.rawValue]
    #expect(fuseBytecodes(three) == [Opcode.pushTempPushTemp.rawValue, 0, p, 1, p, 2, Opcode.returnTop.rawValue])
    // An extended push_temp (temp 256) is not fused with what follows.
    let ext: [UInt8] = [Opcode.ext.rawValue, 1, p, 0, p, 1, Opcode.returnTop.rawValue]
    #expect(fuseBytecodes(ext) == ext)
    let junk: [UInt8] = [p, 0, 0xEE]
    #expect(fuseBytecodes(junk) == junk)
}

/// Broken variant: a fused opcode whose second part is not there (another
/// instruction, an extended one, the end) is refused by the verifier, so no
/// method with one can be made, loaded or run.
@Test func theVerifierRefusesAFusedOpcodeWithoutItsSecondPart() throws {
    let shape = CodeShape(argc: 0, addressableTemps: 4, literalCount: 0, isBlock: false, needsHome: false,
                          ivarRange: 0..<0, maxStackLimit: 64)
    let ok: [UInt8] = [Opcode.pushTempPushTemp.rawValue, 0, Opcode.pushTemp.rawValue, 1, Opcode.pop.rawValue,
                       Opcode.returnTop.rawValue]
    #expect(throws: Never.self) { try verifyBytecodes(ok, shape) { _ in .other } }
    for bad: [UInt8] in [
        [Opcode.pushTempPushTemp.rawValue, 0, Opcode.pushInt.rawValue, 1, Opcode.pop.rawValue, Opcode.returnTop.rawValue],
        [Opcode.pushTempPushTemp.rawValue, 0, Opcode.ext.rawValue, 0, Opcode.pushTemp.rawValue, 1, Opcode.pop.rawValue,
         Opcode.returnTop.rawValue],
        [Opcode.pushTempPushTemp.rawValue, 0, Opcode.pushTempPushTemp.rawValue, 1, Opcode.pushTemp.rawValue, 2, Opcode.pop.rawValue,
         Opcode.pop.rawValue, Opcode.returnTop.rawValue],
        [Opcode.pushTemp.rawValue, 0, Opcode.dupStoreTemp.rawValue],
    ] {
        #expect(throws: BytecodeIssue.self) { try verifyBytecodes(bad, shape) { _ in .other } }
    }
}

/// kasm reads and writes the fused mnemonics: a fused instruction written
/// by hand is its first part, with the second on the next line.
@Test func kasmTakesFusedMnemonics() throws {
    let h = try Harness(runOf("fused_push_temp_push_int 0\n push_int 5\n add\n return_top"))
    defer { h.destroy() }
    #expect(try h.value("run:of:", [37, 1]) == 42)
    #expect(try runOfBytes(h).first == Opcode.pushTempPushInt.rawValue)
    #expect(throws: LoadError.self) {
        let b = try Harness(runOf("fused_push_temp_push_int 0\n push_temp 0\n add\n return_top"))
        b.destroy()
    }
    for op in Opcode.allCases where op.fusedParts != nil {
        #expect(Opcode(mnemonic: op.mnemonic) == op)
        #expect(!op.isExtensible)
    }
}
