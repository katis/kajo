/// A slot in the root registry: an external reference the collector marks
/// from and `becomeForward` rewrites.
struct RootHandle: Hashable, Sendable {
    let index: Int
}

extension ObjectMemory {
    // MARK: - root registry (world stopped, or the only thread)

    @discardableResult
    func addRoot(_ v: Oop) -> RootHandle {
        precondition(v != .none, "a root holds an object or a SmallInteger")
        if let i = unsafe gc.pointee.freeRootSlots.popLast() {
            unsafe gc.pointee.roots[Int(i)] = v.raw
            return RootHandle(index: Int(i))
        }
        unsafe gc.pointee.roots.append(v.raw)
        return unsafe RootHandle(index: gc.pointee.roots.count - 1)
    }

    func root(_ h: RootHandle) -> Oop {
        let v = unsafe Oop(raw: gc.pointee.roots[h.index])
        precondition(v != .none, "removed root")
        return v
    }

    func setRoot(_ h: RootHandle, _ v: Oop) {
        precondition(unsafe v != .none && gc.pointee.roots[h.index] != 0, "removed root")
        unsafe gc.pointee.roots[h.index] = v.raw
    }

    func removeRoot(_ h: RootHandle) {
        precondition(unsafe gc.pointee.roots[h.index] != 0, "root removed twice")
        unsafe gc.pointee.roots[h.index] = 0
        unsafe gc.pointee.freeRootSlots.append(Int32(h.index))
    }

    var rootCount: Int { unsafe gc.pointee.roots.count }

    /// Every registered root (module 7's host worker scans them at its
    /// round acknowledgements: only host calls change the registry, one at
    /// a time, inside the VM).
    func forEachRegisteredRoot(_ body: (Oop) -> Void) {
        let rs = unsafe gc.pointee.roots
        for i in 0..<rs.count where rs[i] != 0 { body(Oop(raw: rs[i])) }
    }

    // MARK: - class table

    /// Register a class oop (or `.none`, set later) and answer its index.
    /// Instances carry the index in their header; the table is a root.
    @discardableResult
    func registerClass(_ classOop: Oop) -> UInt64 {
        let n = unsafe gc.pointee.classTable.count
        precondition(UInt64(n) <= Header.maxClassIndex, "class table full")
        unsafe gc.pointee.classTable.append(classOop.raw)
        unsafe gc.pointee.classFormats.append(0)
        return UInt64(n)
    }

    /// Module 8e: take back the last `n` registrations, which nothing
    /// refers to yet (the define primitive when the heap fills between
    /// registering a class and making its object). World stopped.
    func unregisterLastClasses(_ n: Int) {
        for _ in 0..<n {
            _ = unsafe gc.pointee.classTable.popLast()
            _ = unsafe gc.pointee.classFormats.popLast()
        }
    }

    func classOop(_ index: UInt64) -> Oop {
        unsafe Oop(raw: gc.pointee.classTable[Int(index)])
    }

    func setClassOop(_ index: UInt64, _ classOop: Oop) {
        precondition(index != 0)
        unsafe gc.pointee.classTable[Int(index)] = classOop.raw
    }

    var classCount: Int { unsafe gc.pointee.classTable.count }

    func isRegisteredClass(_ index: UInt64) -> Bool {
        index != 0 && index < UInt64(classCount)
    }
}
