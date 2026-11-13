// The run line's and the shells' `stopsByKind`: per stop kind the count,
// the longest stop, the longest time to safepoint and, for the stop with
// that longest time to safepoint, who parked last and from where. The
// allocation stalls' device rows had one scavenge that waited 141 ms for
// its safepoint; the row must name the participant.

import Testing
@testable import KajoVM

@Test func stopsByKindNamesTheLastParkerOfTheLongestWait() {
    func stop(_ kind: StopKind, ttsp: UInt64, pause: UInt64, slowest: Int, via: ParkVia = .poll) -> StopRecord {
        var r = StopRecord(timeToSafepointNs: ttsp, pauseNs: pause, slowest: slowest, requester: 1)
        r.kind = kind
        r.slowestVia = via
        return r
    }
    // Five background workers: 0 main, 1 to 5 workers, 6 host, 7 the
    // marker, 8 the young collector.
    let stops = [
        stop(.scavenge, ttsp: 500_000, pause: 12_000_000, slowest: 3),
        // The longest wait is not the longest stop: its parker is the one named.
        stop(.scavenge, ttsp: 141_290_000, pause: 5_000_000, slowest: 7, via: .wait),
        stop(.scavenge, ttsp: 100_000, pause: 1_000_000, slowest: 0),
        stop(.finalMark, ttsp: 40_000, pause: 300_000, slowest: -1),
        stop(.initialMark, ttsp: 70_000, pause: 900_000, slowest: 8, via: .stopper),
        stop(.sweep, ttsp: 20_000, pause: 100_000, slowest: 6),
    ]
    let line = stopsByKind(stops, workerCount: 7)
    #expect(line == "scavenge:3/12.00/141.29/marker/wait,finalMark:1/0.30/0.04/-/-,initialMark:1/0.90/0.07/young/stopper,sweep:1/0.10/0.02/host/poll")
    #expect(stopsByKind([], workerCount: 7) == "-")
    #expect(participantName(0, workerCount: 7) == "main")
    #expect(participantName(5, workerCount: 7) == "w5")
    #expect(participantName(9, workerCount: 7) == "9")
    // What scripts/shell-report.py reads of an item is unchanged: the
    // count and the longest stop are still the first two fields.
    let fields = line.split(separator: ",")[0].split(separator: ":")[1].split(separator: "/")
    #expect(fields[0] == "3" && fields[1] == "12.00")
}
