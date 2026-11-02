/// The object model v0 (experiments/vm-language-bench SPEC-SHARED.md
/// "Well-known class indices"), plus Message for `doesNotUnderstand:` and
/// (module 3) Process and Semaphore.
/// There are no metaclasses: every class object is an instance of Class.
enum WellKnown {
    static let smallInteger: UInt64 = 1
    static let undefinedObject: UInt64 = 2
    static let trueClass: UInt64 = 3
    static let falseClass: UInt64 = 4
    static let classClass: UInt64 = 5
    static let method: UInt64 = 6
    static let array: UInt64 = 7
    static let byteArray: UInt64 = 8
    static let symbol: UInt64 = 9
    static let methodDict: UInt64 = 10
    static let object: UInt64 = 11
    static let message: UInt64 = 12
    /// Module 3's (Processes/ProcessLayout.swift). Sealed like the
    /// structural classes: their slots are the scheduler's.
    static let process: UInt64 = 13
    static let semaphore: UInt64 = 14
    static let firstUserClass: UInt64 = 15

    /// Name, index and instance size, in index order.
    static let classes: [(name: String, index: UInt64)] = [
        ("SmallInteger", smallInteger), ("UndefinedObject", undefinedObject), ("True", trueClass),
        ("False", falseClass), ("Class", classClass), ("Method", method), ("Array", array),
        ("ByteArray", byteArray), ("Symbol", symbol), ("MethodDict", methodDict), ("Object", object),
        ("Message", message), ("Process", process), ("Semaphore", semaphore),
    ]

    static func instSize(_ index: UInt64) -> Int {
        switch index {
        case classClass: ClassLayout.size
        case method: MethodLayout.size
        case symbol: 1
        case message: MessageLayout.size
        case process: ProcessLayout.size
        case semaphore: SemaphoreLayout.size
        default: 0
        }
    }
}

/// Class object slots.
enum ClassLayout {
    static let superclass = 0
    static let methodDict = 1
    /// The class name as a Symbol (the experiments left it nil).
    static let name = 2
    static let instSize = 3
    static let classIndex = 4
    static let size = 5
}

/// Method object slots.
enum MethodLayout {
    static let bytecodes = 0
    static let literals = 1
    static let argc = 2
    static let temps = 3
    static let maxStack = 4
    static let selector = 5
    /// 0: none.
    static let primitive = 6
    static let size = 7
}

/// The argument of `doesNotUnderstand:`.
enum MessageLayout {
    static let selector = 0
    static let arguments = 1
    static let size = 2
}

/// A method dictionary: a pointer object of 2 x capacity slots, capacity a
/// power of two at least max(8, 2 x count). Key at 2i, method at 2i + 1,
/// empty key nil, linear probing from the hash. Oops never change
/// (ADR 0003), so hashing a selector's oop is stable across collections.
enum MethodDictionary {
    @_transparent
    static func hash(_ selector: Oop) -> Int { Int(truncatingIfNeeded: selector.raw &>> 4) }

    static func capacity(for count: Int) -> Int {
        var c = 8
        while c < 2 * count { c *= 2 }
        return c
    }
}
