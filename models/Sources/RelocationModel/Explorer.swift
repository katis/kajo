// Exhaustive search over every interleaving of the model's steps, with
// state hashing to prune revisits. Breadth-first, so each violation found is
// one with the fewest steps: the shortest trace that breaks the claim.

import Foundation

/// A violation with the interleaving that reaches it, one line per step.
public struct Trace: Sendable, CustomStringConvertible {
    public var claim: Claim
    public var message: String
    public var steps: [String]

    public var description: String {
        var s = "claim \(claim) violated: \(message)\n"
        for (i, step) in steps.enumerated() { s += "  \(i + 1). \(step)\n" }
        return s
    }
}

public struct Report: Sendable, CustomStringConvertible {
    /// Distinct states reached (violating states are not expanded).
    public var states: Int
    public var transitions: Int
    /// The largest number of steps from the start to any state on a shortest
    /// path: the longest trace breadth-first search produces.
    public var longestTrace: Int
    /// Runs that ended with every thread finished.
    public var finishedRuns: Int
    public var seconds: Double
    /// The shortest violating trace per claim.
    public var violations: [Claim: Trace]

    public var description: String {
        var s = "\(states) states, \(transitions) transitions, longest trace \(longestTrace) steps, \(finishedRuns) finished states, \(String(format: "%.2f", seconds)) s"
        if violations.isEmpty { s += ", no violations" }
        for claim in Claim.allCases { if let t = violations[claim] { s += "\n" + t.description } }
        return s
    }
}

public func explore(_ config: Configuration, stopAtFirstViolation: Bool = false) -> Report {
    let model = Model(config)
    let start = Date()
    var states: [State] = [model.initialState()]
    var parent: [Int32] = [-1]
    var depth: [Int32] = [0]
    var seen: Set<UInt64> = [states[0].fingerprint()]
    var transitions = 0
    var finished = 0
    var violations: [Claim: Trace] = [:]

    func path(to i: Int) -> [Int] {
        var p: [Int] = []
        var k = i
        while k >= 0 { p.append(k); k = Int(parent[k]) }
        return p.reversed()
    }
    func labels(along p: [Int]) -> [String] {
        zip(p, p.dropFirst()).map { a, b in
            model.successors(states[a], labels: true).first { $0.next == states[b] }!.label
        }
    }

    var head = 0
    search: while head < states.count {
        let current = states[head]
        let i = head
        head += 1
        let steps = model.successors(current, labels: false)
        if steps.isEmpty {
            if let v = model.terminalViolation(current) {
                if violations[v.claim] == nil {
                    let p = path(to: i)
                    violations[v.claim] = Trace(claim: v.claim, message: v.message, steps: labels(along: p) + ["(no step can follow)"])
                    if stopAtFirstViolation { break search }
                }
            } else {
                finished += 1
            }
            continue
        }
        for (k, step) in steps.enumerated() {
            transitions += 1
            if let v = step.violation {
                if violations[v.claim] == nil {
                    let p = path(to: i)
                    let last = model.successors(current, labels: true)[k].label
                    violations[v.claim] = Trace(claim: v.claim, message: v.message, steps: labels(along: p) + [last])
                    if stopAtFirstViolation { break search }
                }
                continue
            }
            if seen.insert(step.next.fingerprint()).inserted {
                states.append(step.next)
                parent.append(Int32(i))
                depth.append(depth[i] + 1)
            }
        }
    }
    return Report(
        states: states.count, transitions: transitions,
        longestTrace: Int(depth.max() ?? 0), finishedRuns: finished,
        seconds: Date().timeIntervalSince(start), violations: violations)
}
