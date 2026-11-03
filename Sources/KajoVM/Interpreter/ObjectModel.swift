/// The object model v1 (ADR 0009, module 8): the well-known classes the VM
/// knows by index, the slot layouts it trusts, and the classic metaclasses.
///
/// Every class is the sole instance of its metaclass: a class object's
/// header names its metaclass's index, a metaclass object's names
/// `Metaclass`. `Foo class superclass` is `Foo superclass class`, and
/// `Object class superclass` is `Class`, so class-side lookups end in
/// `Class`, `ClassDescription`, `Behavior` and `Object`. The well-known
/// classes take indices 1 to 26, their metaclasses 27 to 52 (in the same
/// order), and the loader gives every user class two consecutive indices,
/// the class's and its metaclass's, from 53.
enum WellKnown {
    static let smallInteger: UInt64 = 1
    static let undefinedObject: UInt64 = 2
    static let trueClass: UInt64 = 3
    static let falseClass: UInt64 = 4
    /// `Class`: the superclass of `Object class`. Nothing is a direct
    /// instance of it.
    static let classClass: UInt64 = 5
    static let method: UInt64 = 6
    static let array: UInt64 = 7
    static let byteArray: UInt64 = 8
    /// A byte object of UTF-8, interned (ADR 0009 section 8).
    static let symbol: UInt64 = 9
    static let methodDict: UInt64 = 10
    static let object: UInt64 = 11
    static let message: UInt64 = 12
    /// Module 3's (Processes/ProcessLayout.swift). Sealed like the
    /// structural classes: their slots are the scheduler's.
    static let process: UInt64 = 13
    static let semaphore: UInt64 = 14
    // Module 8.
    static let smallFloat: UInt64 = 15
    static let character: UInt64 = 16
    /// A boxed double: 8 bytes, little-endian (what SmallFloat cannot hold).
    static let float: UInt64 = 17
    static let largePositiveInteger: UInt64 = 18
    static let largeNegativeInteger: UInt64 = 19
    static let string: UInt64 = 20
    static let blockClosure: UInt64 = 21
    static let context: UInt64 = 22
    static let metaclass: UInt64 = 23
    static let behavior: UInt64 = 24
    static let classDescription: UInt64 = 25
    static let pragma: UInt64 = 26

    static let count: UInt64 = 26
    static let firstUserClass: UInt64 = 2 * count + 1

    /// The metaclass of well-known class `i`.
    static func metaclass(of i: UInt64) -> UInt64 { i + count }

    struct Definition {
        let name: String
        let index: UInt64
        /// nil: no superclass (Object).
        let superclass: String?
        let format: ClassFormat
    }

    private static func fixed(_ n: Int, sealed: Bool = false) -> ClassFormat {
        ClassFormat(namedSlots: n, kind: .fixed, sealed: sealed)
    }

    private static func bytes() -> ClassFormat { ClassFormat(namedSlots: 0, kind: .bytes) }

    /// Name, index, superclass and format, in index order.
    static let definitions: [Definition] = [
        Definition(name: "SmallInteger", index: smallInteger, superclass: "Object", format: fixed(0)),
        Definition(name: "UndefinedObject", index: undefinedObject, superclass: "Object", format: fixed(0)),
        Definition(name: "True", index: trueClass, superclass: "Object", format: fixed(0)),
        Definition(name: "False", index: falseClass, superclass: "Object", format: fixed(0)),
        Definition(name: "Class", index: classClass, superclass: "ClassDescription",
                   format: fixed(ClassLayout.size, sealed: true)),
        Definition(name: "CompiledMethod", index: method, superclass: "Object", format: fixed(MethodLayout.size, sealed: true)),
        Definition(name: "Array", index: array, superclass: "Object", format: ClassFormat(namedSlots: 0, kind: .variable)),
        Definition(name: "ByteArray", index: byteArray, superclass: "Object", format: bytes()),
        Definition(name: "Symbol", index: symbol, superclass: "String", format: bytes()),
        Definition(name: "MethodDictionary", index: methodDict, superclass: "Object",
                   format: ClassFormat(namedSlots: 0, kind: .variable, sealed: true)),
        Definition(name: "Object", index: object, superclass: nil, format: fixed(0)),
        Definition(name: "Message", index: message, superclass: "Object", format: fixed(MessageLayout.size)),
        Definition(name: "Process", index: process, superclass: "Object", format: fixed(ProcessLayout.size, sealed: true)),
        Definition(name: "Semaphore", index: semaphore, superclass: "Object", format: fixed(SemaphoreLayout.size, sealed: true)),
        Definition(name: "SmallFloat", index: smallFloat, superclass: "Float", format: fixed(0)),
        Definition(name: "Character", index: character, superclass: "Object", format: fixed(0)),
        Definition(name: "Float", index: float, superclass: "Object", format: bytes()),
        Definition(name: "LargePositiveInteger", index: largePositiveInteger, superclass: "Object", format: bytes()),
        Definition(name: "LargeNegativeInteger", index: largeNegativeInteger, superclass: "LargePositiveInteger",
                   format: bytes()),
        Definition(name: "String", index: string, superclass: "Object", format: bytes()),
        Definition(name: "BlockClosure", index: blockClosure, superclass: "Object",
                   format: ClassFormat(namedSlots: ClosureLayout.size, kind: .variable, sealed: true)),
        Definition(name: "Context", index: context, superclass: "Object",
                   format: ClassFormat(namedSlots: ContextLayout.size, kind: .variable, sealed: true)),
        Definition(name: "Metaclass", index: metaclass, superclass: "ClassDescription",
                   format: ClassFormat(namedSlots: MetaclassLayout.size, kind: .fixed, sealed: true, behaviors: true)),
        Definition(name: "Behavior", index: behavior, superclass: "Object", format: fixed(ClassLayout.size, sealed: true)),
        Definition(name: "ClassDescription", index: classDescription, superclass: "Behavior",
                   format: fixed(ClassLayout.size, sealed: true)),
        Definition(name: "Pragma", index: pragma, superclass: "Object", format: fixed(PragmaLayout.size)),
    ]

    /// Name and index, in index order (module 2's form).
    static let classes: [(name: String, index: UInt64)] = definitions.map { ($0.name, $0.index) }

    static func instSize(_ index: UInt64) -> Int {
        definitions.first { $0.index == index }?.format.namedSlots ?? 0
    }

    /// The format of a metaclass whose class objects have `classSlots`
    /// slots: fixed, sealed, its instances behaviors.
    static func metaclassFormat(classSlots: Int) -> ClassFormat {
        ClassFormat(namedSlots: classSlots, kind: .fixed, sealed: true, behaviors: true)
    }
}

/// Class object slots (a class is an instance of its metaclass). Class-side
/// instance variables follow them.
enum ClassLayout {
    static let superclass = 0
    static let methodDict = 1
    /// The class name as a Symbol (nil in a metaclass).
    static let name = 2
    /// Named slots of an instance.
    static let instSize = 3
    /// The index instances carry in their headers.
    static let classIndex = 4
    static let size = 5
}

/// A metaclass object: the class layout, then the one class it describes.
enum MetaclassLayout {
    static let thisClass = ClassLayout.size
    static let size = ClassLayout.size + 1
}

/// Method object slots (`CompiledMethod`). A block method is a Method too,
/// held in its outer method's literal frame (ADR 0009 section 10).
enum MethodLayout {
    static let bytecodes = 0
    static let literals = 1
    static let argc = 2
    /// Words of the frame between the arguments and the header: the temps,
    /// and for a block method its copied values first and its closure last.
    static let temps = 3
    static let maxStack = 4
    /// nil for a block method.
    static let selector = 5
    /// 0: none.
    static let primitive = 6
    /// `MethodFlags`, a SmallInteger.
    static let flags = 7
    /// The class the method was compiled in (`super` looks up from its
    /// superclass); a block method's is its outer method's.
    static let methodClass = 8
    /// A block method's copied values (0 for a method).
    static let copied = 9
    static let size = 10
}

/// Bits of a method's flags word.
enum MethodFlags {
    /// `ensure:` and `ifCurtailed:`: an unwind mark (ADR 0009 section 5).
    static let unwind: Int64 = 1
    /// `on:do:`: a handler mark.
    static let handler: Int64 = 2
    /// A block method: run by a closure, returns with `block_return` or
    /// `nonlocal_return`.
    static let block: Int64 = 4
    /// A block method that returns non-locally, itself or through a block
    /// it creates: its closures carry a home Context.
    static let needsHome: Int64 = 8
    static let all: Int64 = 15
}

/// The argument of `doesNotUnderstand:`.
enum MessageLayout {
    static let selector = 0
    static let arguments = 1
    static let size = 2
}

/// `BlockClosure`: a block method, the receiver of its home, the home
/// Context when the block can return non-locally (nil otherwise), then the
/// copied values (ADR 0009 section 4). Sealed: the activation trusts it.
enum ClosureLayout {
    static let method = 0
    static let receiver = 1
    static let home = 2
    static let size = 3
}

/// `Context` (ADR 0009 section 3): a frame materialized on demand. While
/// the frame lives, `frame` is its header index on the Process's stack and
/// reads and writes go through the frame; when the frame returns (or is
/// cut by an unwind, or its Process ends) the Context is detached: `frame`
/// nil, the temps copied into the indexed slots, `pc` the last one. Sealed.
enum ContextLayout {
    /// The frame's header index (SmallInteger), nil once detached.
    static let frame = 0
    /// The Process whose stack holds the frame; nil for module 2's
    /// standalone interpreter.
    static let process = 1
    static let method = 2
    static let receiver = 3
    /// The closure of a block activation, nil for a method's.
    static let closure = 4
    /// nil while live; the pc offset once detached.
    static let pc = 5
    /// The frame's return marker (`FrameMarker`) while the Context sits in
    /// the frame's context word.
    static let marker = 6
    static let size = 7
}

/// A method's pragma, a literal (selector, arguments, and the method, set
/// by the loader). 8b reifies these; there is no index yet.
enum PragmaLayout {
    static let selector = 0
    static let arguments = 1
    static let method = 2
    static let size = 3
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
