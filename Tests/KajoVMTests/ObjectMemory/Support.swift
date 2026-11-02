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
