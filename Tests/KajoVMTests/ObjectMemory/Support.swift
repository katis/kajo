@testable import KajoVM

/// A small object memory for one test; destroyed by the caller.
func makeMemory(heapBlocks: Int = 64, entries: Int = 1 << 16, chunk: Int = 256,
                stress: StressFlags = [], verify: Bool = true,
                onFailure: VerifyFailurePolicy = .trap) throws -> ObjectMemory {
    var c = ObjectMemoryConfig()
    c.heapBytes = heapBlocks * BlockHeap.blockBytes
    c.entryCapacity = entries
    c.entryChunk = chunk
    c.stress = stress
    c.verify = verify
    c.onVerifyFailure = onFailure
    return try ObjectMemory(c)
}

let fillValue = Oop(smallInteger: 0)

func int(_ v: Int64) -> Oop { Oop(smallInteger: v) }

/// A tiny world for collector tests: a registered `nil` (class 1, rooted),
/// and classes registered for indices 2... on demand.
struct World {
    let om: ObjectMemory
    let ctx: AllocContext
    let nilObj: Oop

    init(_ om: ObjectMemory, classes: Int = 8) {
        self.om = om
        ctx = om.makeContext()
        // Class oops are plain objects here; the class table only needs a
        // reference per index. Index 1 is nil's class.
        let meta = om.registerClass(.none)
        let n = om.tryAllocate(ctx, classIndex: meta, slots: 0, fill: Oop(smallInteger: 0))
        nilObj = n
        om.setClassOop(meta, n)
        for _ in 0..<classes { om.registerClass(n) }
        _ = om.addRoot(n)
    }

    /// Allocate, collecting when needed; traps if the heap is full.
    func new(_ cls: UInt64 = 2, _ slots: Int = 0, extraRoots: [Oop] = []) -> Oop {
        guard let o = om.allocate(ctx, classIndex: cls, slots: slots, fill: nilObj, extraRoots: extraRoots) else {
            fatalError("heap full")
        }
        return o
    }

    func bytes(_ count: Int, cls: UInt64 = 3) -> Oop {
        guard let o = om.allocateBytes(ctx, classIndex: cls, count: count) else { fatalError("heap full") }
        return o
    }
}
