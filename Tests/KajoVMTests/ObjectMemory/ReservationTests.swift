// Collectors review, finding 6: the object memory reserves four ranges of
// address space (the heap with its alias, the entry table, the mark bytes,
// the old map), and a failure after the first released only the heap: the
// entry table (up to 64 GiB) and the mark bytes leaked. The probe records
// every reservation and refuses the n-th one.

import Testing
@testable import KajoVM

private func probedConfig(_ probe: ReservationProbe) -> ObjectMemoryConfig {
    var c = ObjectMemoryConfig()
    c.heapBytes = 64 * BlockHeap.blockBytes
    c.entryCapacity = 1 << 16
    c.reservations = probe
    return c
}

@Test(arguments: 1...4)
func aFailedReservationReleasesTheOnesBeforeIt(_ failAt: Int) {
    let probe = ReservationProbe(failAt: failAt)
    #expect(throws: ObjectMemoryError.self) { _ = try ObjectMemory(probedConfig(probe)) }
    #expect(probe.made == failAt - 1)
    #expect(probe.live.isEmpty, "left reserved: \(probe.live)")
}

@Test func anObjectMemoryReleasesEveryReservation() throws {
    let probe = ReservationProbe()
    let om = try ObjectMemory(probedConfig(probe))
    #expect(probe.made == 4 && probe.live.count == 4)
    om.destroy()
    #expect(probe.live.isEmpty)
}

/// Beside it: an Image whose boot fails (the entry table too small for the
/// well-known objects) owns the memory it was given, which no caller can
/// reach, and destroys it.
@Test func anImageWhoseBootFailsReleasesItsMemory() {
    let probe = ReservationProbe()
    var c = probedConfig(probe)
    c.entryCapacity = 64
    c.entryChunk = 16
    #expect(throws: LoadError.self) { _ = try Image(memory: ObjectMemory(c)) }
    #expect(probe.made == 4 && probe.live.isEmpty, "left reserved: \(probe.live)")
}
