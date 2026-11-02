// The memory model the explorer runs the protocol under.
// docs/models/relocation.md "Memory model" is the prose version of this file.
//
// One shared array of words, read and written atomically: the model is
// multicopy atomic (a store, once it leaves its thread, is seen by every
// other thread at once), as ARMv8 and x86 are. The only relaxation is a
// store buffer per thread:
//
// - Every store, whatever its order, goes into the issuing thread's buffer.
// - A load reads the thread's own newest buffered store to that address if
//   there is one (store forwarding), else shared memory. So a load can
//   overtake the thread's earlier stores to other addresses: store->load
//   reordering, the one reordering that breaks Dekker-style protocols.
// - A seq_cst load may not overtake an earlier seq_cst store of its thread:
//   it is enabled only when no seq_cst store is buffered. That is the rule
//   that puts seq_cst stores and loads into one total order. A release store
//   followed by an acquire (or seq_cst) load may still be reordered, as C++
//   allows and as ARMv8's stlr + ldapr do.
// - Buffered stores leave the buffer (drain) one at a time, as separate
//   steps the scheduler interleaves with everything else. A release or
//   seq_cst store drains only when it is the oldest entry (everything before
//   it is visible first). A relaxed store may drain ahead of older entries to
//   other addresses (store->store reordering of relaxed stores, and of a
//   later relaxed store past an earlier release store), never ahead of an
//   older store to the same address (coherence).
// - seq_cst read-modify-writes, seq_cst fences and mutex operations are full
//   fences: enabled only with an empty buffer, then act on shared memory.
//
// Not modelled: load->load and load->store reordering (loads are performed
// in program order at the instant of their step, which also gives address
// dependencies for free), non-multicopy-atomic visibility (POWER, the C++
// abstract machine), and speculation. See the doc's "Limits".

/// The C++ / Swift `Atomic` orderings the protocol uses.
public enum Order: UInt8, Hashable, Sendable, CustomStringConvertible {
    case relaxed, acquire, release, seqCst

    public var description: String {
        switch self {
        case .relaxed: "relaxed"
        case .acquire: "acquire"
        case .release: "release"
        case .seqCst: "seq_cst"
        }
    }
}

struct BufferedStore: Hashable {
    var address: Int
    var value: Int
    var order: Order
}

struct Memory: Hashable {
    var words: [Int]
    var buffers: [[BufferedStore]]

    init(words: [Int], threads: Int) {
        self.words = words
        self.buffers = Array(repeating: [], count: threads)
    }

    func isDrained(_ t: Int) -> Bool { buffers[t].isEmpty }

    /// The value thread `t` reads at `address`, or nil when the load is not
    /// enabled yet (a seq_cst load behind a buffered seq_cst store).
    func load(_ t: Int, _ address: Int, _ order: Order) -> Int? {
        let buffer = buffers[t]
        if order == .seqCst && buffer.contains(where: { $0.order == .seqCst }) { return nil }
        if let forwarded = buffer.last(where: { $0.address == address }) { return forwarded.value }
        return words[address]
    }

    mutating func store(_ t: Int, _ address: Int, _ value: Int, _ order: Order) {
        precondition(order != .acquire, "no acquire stores")
        buffers[t].append(BufferedStore(address: address, value: value, order: order))
    }

    /// Indices of thread `t`'s buffered stores that may drain next.
    func drainable(_ t: Int) -> [Int] {
        let buffer = buffers[t]
        var result: [Int] = []
        for i in buffer.indices {
            if i == 0 { result.append(0); continue }
            if buffer[i].order != .relaxed { continue }
            if buffer[..<i].contains(where: { $0.address == buffer[i].address }) { continue }
            result.append(i)
        }
        return result
    }

    /// Make thread `t`'s buffered store `i` visible to every thread.
    mutating func drain(_ t: Int, _ i: Int) -> BufferedStore {
        let entry = buffers[t].remove(at: i)
        words[entry.address] = entry.value
        return entry
    }
}
