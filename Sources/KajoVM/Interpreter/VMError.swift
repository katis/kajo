/// An error a running program hit. The interpreter never exits or traps on
/// one: it stops, leaves the stack as it was for inspection, and returns
/// this to its caller.
public struct VMError: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Kind: String, Sendable {
        /// No method for the selector and no `doesNotUnderstand:` either.
        case doesNotUnderstand
        /// A conditional jump popped something other than true or false.
        case mustBeBoolean
        /// A primitive failed and its method has no bytecodes to fall into.
        case primitiveFailed
        /// The next frame does not fit the stack.
        case stackOverflow
        /// An allocation found no room after a collection and a compaction.
        case outOfMemory
        /// push_ivar or store_ivar named a slot the receiver does not have
        /// (become: can change a running method's receiver).
        case invalidSlotAccess
        /// An opcode outside the bytecode set.
        case invalidBytecode
    }

    public let kind: Kind
    /// The selector being sent (doesNotUnderstand, primitiveFailed,
    /// stackOverflow, outOfMemory), if any.
    public let selector: String?
    /// The receiver's class, or the class of the offending value.
    public let receiverClass: String?
    /// The method running when it happened, `Class>>selector`.
    public let method: String?
    /// Offset of the failing instruction in that method's bytecodes.
    public let pc: Int
    /// The primitive number, for primitiveFailed.
    public let primitive: Int

    public var description: String {
        var s = "\(kind.rawValue)"
        if let selector { s += " #\(selector)" }
        if let receiverClass { s += " (receiver \(receiverClass))" }
        if primitive != 0 { s += " primitive \(primitive)" }
        if let method { s += " in \(method) at pc \(pc)" }
        return s
    }
}
