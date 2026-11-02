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
        for _ in 0..<n { append(v) }
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

    mutating func removeAll() { count = 0 }

    mutating func free() {
        unsafe Darwin.free(UnsafeMutableRawPointer(base))
        unsafe base = nil
        count = 0
        capacity = 0
    }

    var isEmpty: Bool { count == 0 }

    func toArray() -> [Element] { (0..<count).map { self[$0] } }
}
