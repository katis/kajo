import Darwin

/// A growable array of plain values in malloc'ed memory: no ARC, usable
/// inside collector loops and inside structs that live in raw memory.
/// The owner frees it explicitly.
@safe struct RawArray<Element: BitwiseCopyable> {
    private var base: UnsafeMutablePointer<Element>?
    private(set) var count = 0
    private(set) var capacity = 0

    init() {}

    init(repeating v: Element, count n: Int) {
        reserve(n)
        if n > 0 { unsafe base.unsafelyUnwrapped.initialize(repeating: v, count: n) }
        count = n
    }

    mutating func reserve(_ n: Int) {
        if n <= capacity { return }
        let bytes = n * MemoryLayout<Element>.stride
        guard let raw = unsafe realloc(UnsafeMutableRawPointer(base), bytes) else { fatalError("out of memory") }
        unsafe base = raw.bindMemory(to: Element.self, capacity: n)
        capacity = n
    }

    @inline(__always)
    mutating func append(_ v: Element) {
        if count == capacity { reserve(Swift.max(16, capacity * 2)) }
        unsafe base.unsafelyUnwrapped[count] = v
        count += 1
    }

    @inline(__always)
    mutating func popLast() -> Element? {
        if count == 0 { return nil }
        count -= 1
        return unsafe base.unsafelyUnwrapped[count]
    }

    @inline(__always)
    subscript(i: Int) -> Element {
        get {
            precondition(i >= 0 && i < count)
            return unsafe base.unsafelyUnwrapped[i]
        }
        set {
            precondition(i >= 0 && i < count)
            unsafe base.unsafelyUnwrapped[i] = newValue
        }
    }

    var last: Element? { count == 0 ? nil : unsafe base.unsafelyUnwrapped[count - 1] }

    mutating func removeAll() { count = 0 }

    /// Drop the first element (a queue that stays short).
    mutating func removeFirst() {
        precondition(count > 0)
        let b = unsafe base.unsafelyUnwrapped
        if count > 1 { unsafe b.update(from: b + 1, count: count - 1) }
        count -= 1
    }

    /// Keep the first `n` elements.
    mutating func truncate(_ n: Int) {
        precondition(n >= 0 && n <= count)
        count = n
    }

    /// The storage, for loops that must not go through the subscript's
    /// checks. Valid until the next append or free.
    var baseAddress: UnsafeMutablePointer<Element>? { unsafe base }

    mutating func free() {
        unsafe Darwin.free(UnsafeMutableRawPointer(base))
        unsafe base = nil
        count = 0
        capacity = 0
    }

    var isEmpty: Bool { count == 0 }

    func toArray() -> [Element] { (0..<count).map { self[$0] } }
}
