/// Why a kasm source was refused. The loader reads untrusted text: every
/// malformed input is one of these, never a trap.
struct LoadError: Error, Equatable, CustomStringConvertible {
    enum Kind: Equatable, Sendable {
        /// A line that is not a class, method, end, label or instruction
        /// where one is expected.
        case syntax
        /// An operand of the wrong form or out of range.
        case badOperand
        case unknownOpcode
        case unknownLabel
        case duplicateLabel
        /// The stack-depth verifier: underflow, two depths meeting at one
        /// instruction, falling off the end, or deeper than the limit.
        case badStack
        /// No bytecodes and no primitive.
        case emptyMethod
        case methodTooLarge
        case tooManyLiterals
        case unknownClass
        case duplicateClass
        case duplicateMethod
        case tooManyClasses
        case tooManyMethods
        /// A superclass cycle, or fewer instance variables than the
        /// superclass, or an instance variable index outside the class.
        case badClass
        /// The object memory has no room for the image.
        case heapFull
        case inputTooLarge
    }

    let kind: Kind
    let message: String
    let file: String
    let line: Int

    init(_ kind: Kind, _ message: String, file: String = "", line: Int = 0) {
        self.kind = kind
        self.message = message
        self.file = file
        self.line = line
    }

    var description: String { "\(file):\(line): \(message)" }
}

/// What the loader accepts. Each is checked before it is relied on.
struct LoaderLimits: Sendable {
    /// Bytes of kasm text per file.
    var maxSourceBytes = 16 << 20
    /// The highest class index the loader assigns.
    var maxClassIndex = 1 << 16
    /// Methods per class: the method dictionary is one object, so it must
    /// fit a block (2 x capacity slots, capacity a power of two >= 2 x count).
    var maxMethodsPerClass = 512
    /// A method's bytecodes are one byte object, at most a block.
    var maxMethodBytes = Header.maxBytes
    /// Literal indices are one byte.
    var maxLiterals = 256
    /// Arguments plus temps; temp indices are one byte.
    var maxTemps = 256
    /// Operand-stack words one activation may use.
    var maxStack = 1024

    init() {}
}
