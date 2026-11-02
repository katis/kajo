/// Bytecode set v0: the experiments' set (experiments/vm-language-bench
/// SPEC-SHARED.md "Bytecodes"), carried in as the encoding the first loader
/// reads, not as Kajo's bytecode set. A bytecode-and-object-model ADR
/// replaces it. Numbering and operand formats live here and only here: the
/// assembler, the stack-depth verifier and the dispatch loop read them from
/// this enum, and frames, sends, primitives and the lookup cache never see
/// an opcode number.
///
/// One byte of opcode, operands after it. The raw values are contiguous from
/// 0 in declaration order, so `Opcode(rawValue:)` is one compare and the
/// dispatch `switch` over the optional is one jump table.
enum Opcode: UInt8, CaseIterable, Sendable {
    case pushTemp = 0x00      // u8 n: push temp n (arguments are temps 0..argc-1)
    case pushLiteral          // u8 n: push literal n
    case pushSelf
    case pushIvar             // u8 n: push receiver slot n
    case storeTemp            // u8 n: pop into temp n
    case storeIvar            // u8 n: pop into receiver slot n
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
    case add                  // special sends: SmallInteger fast path, else a real send
    case sub
    case mul
    case lt
    case gt
    case le
    case ge
    case eq
    case identical            // ==, always inline

    enum Operands: Sendable {
        case none
        /// An unsigned byte: a temp, literal or slot index.
        case index
        /// A signed byte.
        case int8
        /// A literal index (the selector) and an argument count.
        case send
        /// A signed 16-bit little-endian offset from the next instruction.
        case jump
    }

    var operands: Operands {
        switch self {
        case .pushTemp, .pushLiteral, .pushIvar, .storeTemp, .storeIvar: .index
        case .pushInt: .int8
        case .send: .send
        case .jump, .jumpIfTrue, .jumpIfFalse: .jump
        default: .none
        }
    }

    /// Instruction length in bytes, opcode included.
    var length: Int {
        switch operands {
        case .none: 1
        case .index, .int8: 2
        case .send, .jump: 3
        }
    }

    /// The kasm name.
    var mnemonic: String {
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
        }
    }

    /// Decode a byte: one compare. The synthesized `init(rawValue:)` was an
    /// out-of-line call per bytecode. Valid because the raw values are the
    /// case indices (`theOpcodeTableIsTheExperimentsSet` checks it), which
    /// is how a payload-free enum is represented.
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

    /// The selector a special arithmetic or comparison bytecode sends when
    /// its SmallInteger fast path does not apply.
    var specialSelector: String? {
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
        default: nil
        }
    }

    /// Operand-stack words read and the words left in their place, for the
    /// stack-depth verifier. A send's effect depends on its argc.
    func stackEffect(argc: Int) -> (pops: Int, pushes: Int) {
        switch self {
        case .pushTemp, .pushLiteral, .pushSelf, .pushIvar, .pushNil, .pushTrue, .pushFalse, .pushInt: (0, 1)
        case .storeTemp, .storeIvar, .pop, .jumpIfTrue, .jumpIfFalse: (1, 0)
        case .dup: (1, 2)
        case .send: (argc + 1, 1)
        case .returnTop: (1, 0)
        case .returnSelf, .jump: (0, 0)
        case .add, .sub, .mul, .lt, .gt, .le, .ge, .eq, .identical: (2, 1)
        }
    }

    /// Control leaves the instruction other than by falling through.
    var endsBlock: Bool { self == .returnTop || self == .returnSelf || self == .jump }
    var isJump: Bool { operands == .jump }
}

/// The special selectors in intern order (SPEC-SHARED "Boot order", step 3):
/// the eight special-send bytecodes in opcode order, then `==`.
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

/// Arguments a selector takes: binary (first character not a letter) 1,
/// keyword the number of colons, unary 0.
func arity(of selector: String) -> Int {
    guard let c = selector.unicodeScalars.first else { return 0 }
    if !(c.properties.isAlphabetic || c == "_") { return 1 }
    return selector.unicodeScalars.reduce(0) { $0 + ($1 == ":" ? 1 : 0) }
}
