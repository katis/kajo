import Synchronization

// Claiming a young object in a scavenge (docs/modules/nursery.md "The
// scavenge"; experiments/concurrent-relocation SPEC "Claim tag"). Scavenge
// s claims with tag bit 62 + (s & 1). The winning compare-and-swap on the
// header writes the decision: survive (age + 1, the winner's nursery
// index, this tag, the other tag cleared) or promote (young, nursery, age
// and both tags cleared). A participant that loses, or finds the tag set,
// reads the decision from the header: young means it survived. No pass
// clears tags: the next scavenge uses the other bit.

enum ClaimDecision: Equatable, Sendable {
    case survive
    case promote
    /// Promoted because the winner's survivor-to had no room.
    case promoteOverflow
    /// Promotion found no block: kept young in place (the reserve's
    /// fallback, docs/modules/reserve-and-depth.md).
    case keep
}

/// The claim tag bit of scavenge `number` (`sameTag`: the test switch that
/// breaks the alternation).
@inline(__always)
func claimTag(scavenge number: UInt64, sameTag: Bool = false) -> UInt64 {
    sameTag ? 1 &<< Header.claimShift : 1 &<< (Header.claimShift &+ (number & 1))
}

/// The header the winner writes for young header `h`, and its decision.
@inline(__always)
func claimedHeader(_ h: UInt64, tag: UInt64, ageLimit: UInt64, participant: Int, promoteAll: Bool,
                   hasRoom: Bool) -> (UInt64, ClaimDecision) {
    let age = ((h & Header.ageMask) &>> Header.ageShift) &+ 1
    if !promoteAll && age < ageLimit {
        if hasRoom {
            let base = h & ~Header.youngOnlyMask
            return (base | age &<< Header.ageShift | UInt64(participant) &<< Header.nurseryShift | tag, .survive)
        }
        return (h & ~(Header.youngOnlyMask | Header.youngBit), .promoteOverflow)
    }
    return (h & ~(Header.youngOnlyMask | Header.youngBit), .promote)
}

/// The claim protocol on one header word, outside a heap (tests): the same
/// rule the scavenge's compare-and-swap loop runs.
struct ClaimCell {
    var value: UInt64

    init(_ value: UInt64) { self.value = value }

    /// Claim in scavenge `scavenge` as participant `participant`. Answers
    /// whether this call won and the decision (read from the header when
    /// it lost).
    mutating func claim(scavenge: UInt64, ageLimit: UInt64, participant: Int, promoteAll: Bool,
                        hasRoom: Bool) -> (won: Bool, decision: ClaimDecision) {
        let tag = claimTag(scavenge: scavenge)
        let h = value
        if h & Header.youngBit == 0 { return (false, .promote) }
        if h & tag != 0 { return (false, .survive) }
        let (nh, d) = claimedHeader(h, tag: tag, ageLimit: ageLimit, participant: participant, promoteAll: promoteAll,
                                    hasRoom: hasRoom)
        value = nh
        return (true, d)
    }
}
