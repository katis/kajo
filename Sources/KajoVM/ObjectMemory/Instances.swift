// The discoverability follow-up (docs/modules/discoverability.md): the
// walk behind `allInstances` and `instanceCount` (primitives 167 and 168,
// ObjectModel/InstancePrimitives.swift).
//
// World stopped, after module 1's promote-all hook
// (`prepareOldSpaceOperation`) answered no young object: a marking cycle
// was abandoned or its sweep finished and applied (no swept-but-pending
// run is left), every deferred entry free was released, and every live
// young object promoted. So the old map holds exactly the used entries
// (sweep-stop.md's one-owner table: a pending run's entries are free with
// the old-map bit clear, a deferred free is a young entry and none is
// left, a stash's entries are free), and the walk reads the old map's
// words, skipping 64 free entries per zero word, and the header of each
// entry whose bit is set. A large object is one entry (its continuation
// blocks are not entries), so it counts once.

extension ObjectMemory {
    /// Visit every old entry whose class index is in `classes` (a table of
    /// flags by class index), in table order, until `visit` answers false.
    /// Answers the entries visited. World stopped, nothing young.
    @discardableResult
    func walkInstances(of classes: [Bool], skipping skip: Oop = .none, _ visit: (Oop) -> Bool) -> Int {
        let hw = highWater
        let map = oldMap
        let words = Int((hw &+ 63) &>> 6)
        var found = 0
        for w in 0..<words {
            var bits = map.word(w)
            while bits != 0 {
                let b = UInt64(bits.trailingZeroBitCount)
                bits &= bits &- 1
                let e = UInt64(w) &<< 6 | b
                if e == 0 || e >= hw { continue }
                let raw = e &<< 4
                // Belt and braces: the old map's bit is set exactly while the
                // entry holds an old object, so a free one is never here.
                if EntryState.isFree(stateWord(raw)) { continue }
                let ci = Header(raw: headerWord(raw)).classIndex
                guard ci < UInt64(classes.count), classes[Int(ci)], raw != skip.raw else { continue }
                found &+= 1
                if !visit(Oop(raw: raw)) { return found }
            }
        }
        return found
    }
}
