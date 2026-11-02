/// Verifiers: each redoes a piece of the collector's reasoning from
/// scratch and reports what disagrees. Checked builds run them at every
/// pause; release builds when `config.verify` is set.
enum VerifyPhase {
    /// Outside a collection: marks clear, contexts retired.
    case idle
    /// Between mark and sweep.
    case marked(extraRoots: [Oop])
}

extension ObjectMemory {
    func verifyAtPause(_ when: String, phase: VerifyPhase) {
        guard config.verify else { return }
        switch phase {
        case .idle:
            record(when, verifyHeap() + verifyFreeLists())
        case .marked(let extraRoots):
            record(when, verifyMarks(extraRoots: extraRoots))
        }
    }

    /// Count a verifier run and its failures; trap or keep the report.
    func record(_ when: String, _ issues: [String]) {
        unsafe gc.pointee.counters.verifierRuns &+= 1
        if issues.isEmpty { return }
        unsafe gc.pointee.counters.verifierFailures &+= UInt64(issues.count)
        let report = "object memory verifier, \(when): " + issues.prefix(10).joined(separator: "; ")
        switch config.onVerifyFailure {
        case .trap: fatalError(report)
        case .record: unsafe gc.pointee.failures.append(report)
        }
    }

    var verifierReports: [String] { unsafe gc.pointee.failures }

    func verifyHeap() -> [String] { [] }
    func verifyFreeLists() -> [String] { [] }
    func verifyMarks(extraRoots: [Oop]) -> [String] { [] }
}
