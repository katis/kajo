// The collectors' logs (docs/modules/collectors-review.md, finding 3): every
// scavenge, young collection, round, marking cycle and relocation, and every
// main-thread hop, leaves a record. They were Swift arrays nothing trimmed,
// so a shell that runs for days grew by tens of megabytes an hour. Each is
// now a ring of the last `capacity` records (`VMConfig.logCapacity`), with
// the total appended so a reader knows how many were dropped; what the
// reports sum, average or take the maximum of is kept as running
// aggregates beside the ring, so those numbers cover the whole run and
// only percentiles are over the records kept.

/// The last `capacity` records, oldest overwritten first. The storage grows
/// by appending until it holds `capacity` records, then every append
/// overwrites one in place: no allocation once full, so an append under a
/// mutex (the young collections' log) never reallocates. Readers copy the
/// records out (`records`) and never share the storage, so an overwrite
/// never copies it either. Records are plain values (no Swift arrays or
/// references), so an overwrite releases nothing. Not thread safe: each
/// ring has the owner its log has (the stopper, a mutex).
struct RecordRing<Record> {
    private var storage: [Record] = []
    let capacity: Int
    /// Records ever appended.
    private(set) var total: UInt64 = 0

    init(capacity: Int) {
        precondition(capacity >= 1, "a log holds at least one record")
        self.capacity = capacity
    }

    /// Records appended and no longer kept.
    var dropped: UInt64 { total &- UInt64(storage.count) }

    /// Records kept.
    var count: Int { storage.count }

    /// The storage's allocated capacity (tests: it stops growing once the
    /// ring is full).
    var storageCapacity: Int { storage.capacity }

    mutating func append(_ r: Record) {
        if storage.count < capacity {
            storage.append(r)
        } else {
            storage[Int(total % UInt64(capacity))] = r
        }
        total &+= 1
    }

    /// The sequence number the next append gets (`total`); the record of
    /// sequence number `s` is kept while `s >= total - count`.
    private func slot(_ s: UInt64) -> Int? {
        guard s < total, s >= dropped else { return nil }
        return Int(s % UInt64(capacity))
    }

    /// The record with sequence number `s`, if still kept.
    func record(_ s: UInt64) -> Record? { slot(s).map { storage[$0] } }

    /// Change the record with sequence number `s`, if still kept.
    mutating func update(_ s: UInt64, _ change: (inout Record) -> Void) {
        guard let i = slot(s) else { return }
        change(&storage[i])
    }

    /// The newest record.
    var last: Record? { total == 0 ? nil : record(total &- 1) }

    /// The records kept, oldest first, in a new array.
    var records: [Record] {
        var out: [Record] = []
        out.reserveCapacity(storage.count)
        if storage.count < capacity {
            out.append(contentsOf: storage)
        } else {
            let k = Int(total % UInt64(capacity))
            out.append(contentsOf: storage[k...])
            out.append(contentsOf: storage[..<k])
        }
        return out
    }
}
