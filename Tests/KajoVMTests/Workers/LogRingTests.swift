// Collectors review, finding 3: the collectors' logs are rings of
// `VMConfig.logCapacity` records with running totals and a dropped count,
// so a VM that runs for days holds a bounded log while its report still
// sums every collection.

import Testing
@testable import KajoVM

@Test func aRecordRingKeepsTheLastRecordsAndStopsGrowing() {
    var r = RecordRing<Int>(capacity: 5)
    #expect(r.records == [] && r.last == nil && r.dropped == 0)
    for i in 0..<5 { r.append(i) }
    #expect(r.records == [0, 1, 2, 3, 4] && r.dropped == 0)
    let grown = r.storageCapacity
    for i in 5..<1003 { r.append(i) }
    #expect(r.count == 5 && r.total == 1003 && r.dropped == 998)
    #expect(r.records == [998, 999, 1000, 1001, 1002] && r.last == 1002)
    // No allocation once full: the storage never grew past the fill.
    #expect(r.storageCapacity == grown)
    // Records by sequence number, while kept.
    #expect(r.record(1002) == 1002 && r.record(998) == 998 && r.record(997) == nil && r.record(1003) == nil)
    r.update(1000) { $0 = -1 }
    r.update(3) { $0 = -2 }
    #expect(r.records == [998, 999, -1, 1001, 1002])
    // A copy read out does not share the storage: appending after it
    // overwrites in place.
    let before = r.records
    r.append(1003)
    #expect(before == [998, 999, -1, 1001, 1002] && r.records == [999, -1, 1001, 1002, 1003])
    #expect(r.storageCapacity == grown)
}

private func ringRuntime(young: YoungMode, marking: Bool) throws -> Runtime {
    try Runtime(markingSrc, background: 1, start: false, configure: { c in
        c.logCapacity = 8
        c.nursery.bytes = 64 << 10
        c.nursery.age = 1
        c.young.mode = young
        c.marking.enabled = marking
        c.marking.markerThread = false
    })
}

@Test func theScavengeAndCycleLogsKeepTheirCapacityAndTotalEveryRecord() throws {
    let rt = try ringRuntime(young: .stw, marking: true)
    for _ in 0..<12 {
        rt.vm.startCycle()
        rt.finishCycle()
    }
    #expect(rt.runInt("churnLists:", 40) > 0)
    let n = rt.vm.nurseryCounters.scavenges
    let st = rt.vm.scavengeTotals, sl = rt.vm.scavengeLog
    #expect(n > 30 && st.scavenges == n)
    #expect(sl.count == 8 && st.dropped == n - 8)
    #expect(sl.last?.number == n && zip(sl, sl.dropFirst()).allSatisfy { $1.number == $0.number + 1 })
    #expect(st.participants >= n && st.busyNs >= sl.reduce(0) { $0 &+ $1.busyNs })
    let ct = rt.vm.cycleTotals, cl = rt.vm.cycleLog
    #expect(ct.cycles == 12 && ct.completed == 12 && rt.vm.markingCounters.cyclesCompleted == 12)
    #expect(cl.count == 8 && ct.dropped == 4 && cl.allSatisfy(\.completed))
    #expect(ct.markCpuNs >= cl.reduce(0) { $0 &+ $1.markCpuNs } && ct.durationNs >= cl.reduce(0) { $0 &+ $1.durationNs })
    // The report names what the logs dropped.
    let report = Dictionary(uniqueKeysWithValues: nurseryReport(rt.vm, stops: rt.vm.stops, ms: 1) + markingReport(rt.vm, stops: rt.vm.stops))
    #expect(report["scavLogDropped"] == "\(n - 8)" && report["cycleLogDropped"] == "4")
    rt.noFailures()
    rt.stop()
}

@Test func theYoungCollectionAndRoundLogsKeepTheirCapacityAndTotalEveryRecord() throws {
    let rt = try ringRuntime(young: .local, marking: false)
    #expect(rt.runInt("churnLists:", 40) > 0)
    let yc = rt.vm.youngCounters, yt = rt.vm.youngTotals
    let log = rt.vm.youngLog, rounds = rt.vm.roundLog
    #expect(yt.collections == yc.collectionsLocal + yc.collectionsOffloaded && yt.collections > 8)
    #expect(log.count == 8 && yt.droppedCollections == yt.collections - 8)
    #expect(yt.rounds >= UInt64(log.reduce(0) { $0 + $1.rounds }))
    #expect(yt.survivedObjects >= log.reduce(0) { $0 &+ $1.survivedObjects })
    #expect(yt.roundRecords > 8 && rounds.count == 8 && yt.droppedRounds == yt.roundRecords - 8)
    #expect(rounds.allSatisfy { $0.latencyNs <= yt.roundMaxNs })
    let report = Dictionary(uniqueKeysWithValues: youngReport(rt.vm, ms: 1))
    #expect(report["ycLogDropped"] == "\(yt.collections - 8)")
    rt.noFailures()
    rt.stop()
}
