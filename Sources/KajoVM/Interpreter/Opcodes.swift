/// Bytecode set v1 (ADR 0009 section 10). Numbering, operand formats,
/// stack effects and special selectors live here and only here: the
/// assembler, the stack-depth verifier (the kasm loader's and the image
/// loader's) and the dispatch loop read them from this enum, and frames,
/// sends, primitives and the lookup cache never see an opcode number.
///
/// One byte of opcode, operands after it. The raw values are contiguous from
/// 0 in declaration order, so `Opcode.decode` is one compare and the
/// dispatch `switch` is one jump table. Opcodes 0 to 26 are module 2's v0
/// set with its encoding unchanged; v1 appends the rest.
///
/// Operands are one byte (jumps two). The extension prefix `ext hi` makes
/// the first operand of the instruction that follows `hi << 8 | operand`;
/// the assembler emits it when an index does not fit a byte, and the
/// dispatch loop runs an extended instruction out of line.
package enum Opcode: UInt8, CaseIterable, Sendable {
    case pushTemp = 0x00      // u8 n: push temp n (arguments are temps 0..argc-1)
    case pushLiteral          // u8 n: push literal n
    case pushSelf
    case pushIvar             // u8 n: push receiver slot n
    case storeTemp            // u8 n: pop into temp n
    case storeIvar            // u8 n: pop into receiver slot n (read-only checked)
    case pop
    case dup
    case pushNil
    case pushTrue
    case pushFalse
    case pushInt              // i8: push a SmallInteger
    case send                 // u8 literal (selector), u8 argc
    case returnTop
    case returnSelf
    case jump                 // i16 LE, relative to the next instruction
    case jumpIfTrue           // i16 LE; pops; a non-Boolean is an error
    case jumpIfFalse          // i16 LE; pops; a non-Boolean is an error
    case add                  // special sends: a fast path, else a real send
    case sub
    case mul
    case lt
    case gt
    case le
    case ge
    case eq
    case identical            // ==, always inline
    // v1
    case div                  // /
    case intDiv               // //
    case mod                  // \\
    case ne                   // ~=
    case notIdentical         // ~~, always inline
    case at                   // at:
    case atPut                // at:put:
    case size
    case classOf              // class, always inline
    case value
    case value1               // value:
    case value2               // value:value:
    case isNil                // always inline
    case notNil               // always inline
    case sendSuper            // u8 literal (selector), u8 argc: lookup from the method class's superclass
    case pushClosure          // u8 literal (a block method), u8 copied values popped into it
    case pushNewArray         // u8 n: push an Array of n nils (a temp vector)
    case pushTempVectorSlot   // u8 slot, u8 temp: push slot of the temp vector in temp
    case storeTempVectorSlot  // u8 slot, u8 temp: pop into slot of the temp vector in temp
    case pushThisContext
    case blockReturn          // return the top from a block to its caller
    case nonlocalReturn       // return the top from the block's home method
    case ext                  // u8 hi: the next instruction's first operand is hi << 8 | operand

    package enum Operands: Sendable, Equatable {
        case none
        /// An unsigned byte: a temp, literal, slot index or count.
        case index
        /// A signed byte.
        case int8
        /// A literal index (the selector) and an argument count.
        case send
        /// A signed 16-bit little-endian offset from the next instruction.
        case jump
        /// A literal index (a block method) and a copied-value count.
        case closure
        /// A temp-vector slot and the temp holding the vector.
        case vectorSlot
        /// The extension prefix's high byte.
        case prefix
    }

    package var operands: Operands {
        switch self {
        case .pushTemp, .pushLiteral, .pushIvar, .storeTemp, .storeIvar, .pushNewArray: .index
        case .pushInt: .int8
        case .send, .sendSuper: .send
        case .jump, .jumpIfTrue, .jumpIfFalse: .jump
        case .pushClosure: .closure
        case .pushTempVectorSlot, .storeTempVectorSlot: .vectorSlot
        case .ext: .prefix
        default: .none
        }
    }

    /// Instruction length in bytes, opcode included.
    package var length: Int {
        switch operands {
        case .none: 1
        case .index, .int8, .prefix: 2
        case .send, .jump, .closure, .vectorSlot: 3
        }
    }

    /// The first operand may be extended by `ext`.
    package var isExtensible: Bool {
        switch self {
        case .pushTemp, .pushLiteral, .pushIvar, .storeTemp, .storeIvar, .pushNewArray, .send, .sendSuper,
             .pushClosure, .pushTempVectorSlot, .storeTempVectorSlot: true
        default: false
        }
    }

    /// The kasm name.
    package var mnemonic: String {
        switch self {
        case .pushTemp: "push_temp"
        case .pushLiteral: "push_lit"
        case .pushSelf: "push_self"
        case .pushIvar: "push_ivar"
        case .storeTemp: "store_temp"
        case .storeIvar: "store_ivar"
        case .pop: "pop"
        case .dup: "dup"
        case .pushNil: "push_nil"
        case .pushTrue: "push_true"
        case .pushFalse: "push_false"
        case .pushInt: "push_int"
        case .send: "send"
        case .returnTop: "return_top"
        case .returnSelf: "return_self"
        case .jump: "jump"
        case .jumpIfTrue: "jump_if_true"
        case .jumpIfFalse: "jump_if_false"
        case .add: "add"
        case .sub: "sub"
        case .mul: "mul"
        case .lt: "lt"
        case .gt: "gt"
        case .le: "le"
        case .ge: "ge"
        case .eq: "eq"
        case .identical: "identical"
        case .div: "div"
        case .intDiv: "int_div"
        case .mod: "mod"
        case .ne: "ne"
        case .notIdentical: "not_identical"
        case .at: "at"
        case .atPut: "at_put"
        case .size: "size"
        case .classOf: "class_of"
        case .value: "value"
        case .value1: "value1"
        case .value2: "value2"
        case .isNil: "is_nil"
        case .notNil: "not_nil"
        case .sendSuper: "send_super"
        case .pushClosure: "push_closure"
        case .pushNewArray: "push_new_array"
        case .pushTempVectorSlot: "push_tv_slot"
        case .storeTempVectorSlot: "store_tv_slot"
        case .pushThisContext: "push_this_context"
        case .blockReturn: "block_return"
        case .nonlocalReturn: "nonlocal_return"
        case .ext: "ext"
        }
    }

    /// Decode a byte: one compare. The synthesized `init(rawValue:)` was an
    /// out-of-line call per bytecode. Valid because the raw values are the
    /// case indices (`theOpcodeTableIsContiguous` checks it), which is how
    /// a payload-free enum is represented.
    @_transparent
    static func decode(_ b: UInt8) -> Opcode? {
        b < Opcode.count ? unsafe unsafeBitCast(b, to: Opcode.self) : nil
    }

    static let count = UInt8(allCases.count)

    init?(mnemonic: String) {
        guard let op = Opcode.byMnemonic[mnemonic] else { return nil }
        self = op
    }

    private static let byMnemonic = Dictionary(uniqueKeysWithValues: allCases.map { ($0.mnemonic, $0) })

    /// The selector a special-send bytecode sends when its fast path does
    /// not apply (the inline ones, `==`, `~~`, `class`, `isNil`, `notNil`,
    /// have one too, for the compiler and the tables).
    package var specialSelector: String? {
        switch self {
        case .add: "+"
        case .sub: "-"
        case .mul: "*"
        case .lt: "<"
        case .gt: ">"
        case .le: "<="
        case .ge: ">="
        case .eq: "="
        case .identical: "=="
        case .div: "/"
        case .intDiv: "//"
        case .mod: "\\\\"
        case .ne: "~="
        case .notIdentical: "~~"
        case .at: "at:"
        case .atPut: "at:put:"
        case .size: "size"
        case .classOf: "class"
        case .value: "value"
        case .value1: "value:"
        case .value2: "value:value:"
        case .isNil: "isNil"
        case .notNil: "notNil"
        default: nil
        }
    }

    /// Index of this special send's selector in `specialSelectorNames` (and
    /// the interpreter's `specialSelectors`).
    var specialIndex: Int { Opcode.specialIndices[Int(rawValue)] }

    private static let specialIndices: [Int] = {
        var out = [Int](repeating: -1, count: allCases.count)
        var k = 0
        for op in allCases where op.specialSelector != nil {
            out[Int(op.rawValue)] = k
            k += 1
        }
        return out
    }()

    /// Arguments of a special send (receiver excluded).
    package var specialArgc: Int {
        switch self {
        case .atPut, .value2: 2
        case .size, .classOf, .value, .isNil, .notNil: 0
        default: 1
        }
    }

    /// Operand-stack words read and the words left in their place, for the
    /// stack-depth verifier. A send's effect depends on its argc, a
    /// closure's on its copied count (both passed as `argc`).
    func stackEffect(argc: Int) -> (pops: Int, pushes: Int) {
        switch self {
        case .pushTemp, .pushLiteral, .pushSelf, .pushIvar, .pushNil, .pushTrue, .pushFalse, .pushInt,
             .pushNewArray, .pushTempVectorSlot, .pushThisContext: (0, 1)
        case .storeTemp, .storeIvar, .pop, .jumpIfTrue, .jumpIfFalse, .storeTempVectorSlot: (1, 0)
        case .dup: (1, 2)
        case .send, .sendSuper: (argc + 1, 1)
        case .pushClosure: (argc, 1)
        case .returnTop, .blockReturn, .nonlocalReturn: (1, 0)
        case .returnSelf, .jump, .ext: (0, 0)
        case .add, .sub, .mul, .lt, .gt, .le, .ge, .eq, .identical, .div, .intDiv, .mod, .ne, .notIdentical, .at,
             .atPut, .size, .classOf, .value, .value1, .value2, .isNil, .notNil:
            (specialArgc + 1, 1)
        }
    }

    /// Words a slow path may push above the instruction's starting depth
    /// beyond its declared effect: a store into a read-only object pushes
    /// the object, the index and the value for
    /// `modificationForbiddenAt:value:` in place of the value (2 more); a
    /// non-local return through an unwind mark pushes the home Context and
    /// the unwind Context around the value (2 more). The verifier counts
    /// them in `maxStack`. (A unary send's `doesNotUnderstand:` Message and
    /// a store primitive's `modificationForbiddenAt:value:` fit the one word
    /// every frame reserves.)
    var transientDepth: Int {
        switch self {
        case .storeIvar, .storeTempVectorSlot: 2
        case .nonlocalReturn: 2
        default: 0
        }
    }

    /// Control leaves the instruction other than by falling through.
    var endsBlock: Bool {
        self == .returnTop || self == .returnSelf || self == .jump || self == .blockReturn || self == .nonlocalReturn
    }
    package var isJump: Bool { operands == .jump }
    var isReturn: Bool { self == .returnTop || self == .returnSelf || self == .blockReturn || self == .nonlocalReturn }
}

/// The special selectors in intern order: the special-send bytecodes in
/// opcode order.
let specialSelectorNames: [String] = Opcode.allCases.compactMap(\.specialSelector)

/// Operand decoding: the one place that knows how operands are encoded.
enum OperandDecoding {
    @_transparent
    static func int8(_ b: UInt8) -> Int64 { Int64(Int8(bitPattern: b)) }

    @_transparent
    static func jumpOffset(_ lo: UInt8, _ hi: UInt8) -> Int {
        Int(Int16(bitPattern: UInt16(lo) | UInt16(hi) &<< 8))
    }

    static func encodeJump(_ offset: Int) -> (UInt8, UInt8) {
        let v = UInt16(bitPattern: Int16(offset))
        return (UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v &>> 8))
    }
}

/// A decoded instruction (the image loader's verifier and the tests read
/// bytecodes through this; the dispatch loop decodes inline).
struct DecodedInstruction: Equatable {
    let op: Opcode
    let offset: Int
    /// Bytes, the `ext` prefix included.
    let length: Int
    /// The first operand, extended; the second (argc, copied count, temp).
    let a: Int
    let b: Int
}

/// Decode the instruction at `offset`, or nil if it is not one (an unknown
/// byte, a truncated operand, a prefix before a non-extensible opcode or
/// another prefix).
func decodeInstruction(_ bytes: [UInt8], at offset: Int) -> DecodedInstruction? {
    guard offset < bytes.count, var op = Opcode.decode(bytes[offset]) else { return nil }
    var at = offset
    var hi = 0
    if op == .ext {
        guard at + 2 < bytes.count, let next = Opcode.decode(bytes[at + 2]), next.isExtensible else { return nil }
        hi = Int(bytes[at + 1])
        at += 2
        op = next
    }
    guard at + op.length <= bytes.count else { return nil }
    var a = 0, b = 0
    switch op.operands {
    case .none, .prefix: break
    case .index: a = Int(bytes[at + 1])
    case .int8: a = Int(OperandDecoding.int8(bytes[at + 1]))
    case .send, .closure, .vectorSlot:
        a = Int(bytes[at + 1])
        b = Int(bytes[at + 2])
    case .jump: a = OperandDecoding.jumpOffset(bytes[at + 1], bytes[at + 2])
    }
    if hi != 0 || at != offset { a |= hi << 8 }
    return DecodedInstruction(op: op, offset: offset, length: at - offset + op.length, a: a, b: b)
}

/// Arguments a selector takes: binary (first character not a letter) 1,
/// keyword the number of colons, unary 0.
package func arity(of selector: String) -> Int {
    guard let c = selector.unicodeScalars.first else { return 0 }
    if !(c.properties.isAlphabetic || c == "_") { return 1 }
    return selector.unicodeScalars.reduce(0) { $0 + ($1 == ":" ? 1 : 0) }
}
