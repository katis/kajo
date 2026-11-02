// Exhaustive search over every interleaving of a model's steps, with state
// hashing to prune revisits. Breadth-first, so each violation found is one
// with the fewest steps: the shortest trace that breaks the claim. Shared by
// every model in this package (docs/models/relocation.md "Choices").

import Foundation

/// A protocol model the explorer can run: an initial state, the steps
/// enabled in a state, and the checks on a state with no step.
public protocol ExplorableModel {
    associatedtype State: Hashable
    associatedtype Claim: Hashable & Sendable & CaseIterable & CustomStringConvertible

    func initialState() -> State
    /// Every step enabled in `s`. Labels are built only when `labels` is
    /// true (for traces); the explorer matches steps by their next state.
    func successors(_ s: State, labels: Bool) -> [Transition<State, Claim>]
    /// Checks on a state with no successors (end of run, or deadlock).
    func terminalViolation(_ s: State) -> Violation<Claim>?
    /// A 64-bit fingerprint for the visited set (hash compaction).
    func fingerprint(_ s: State) -> UInt64
    /// States the model wants counted (evidence that a run reached a point
    /// of interest, such as a reused entry). Default: none.
    func isWitness(_ s: State) -> Bool
}

extension ExplorableModel {
    public func isWitness(_ s: State) -> Bool { false }
}

public struct Violation<Claim: Hashable & Sendable>: Hashable, Sendable {
    public var claim: Claim
    public var message: String
    @inlinable
    public init(claim: Claim, message: String) {
        self.claim = claim
        self.message = message
    }
}

/// One transition: a label for traces (empty unless asked for), the next
/// state, and the claim it violates, if any.
public struct Transition<State, Claim: Hashable & Sendable> {
    public var label: String
    public var next: State
    public var violation: Violation<Claim>?
    /// `@inlinable`, as everything a model calls per step: an unspecialised
    /// generic call per successor cost the relocation model 20 percent.
    @inlinable
    public init(label: String, next: State, violation: Violation<Claim>?) {
        self.label = label
        self.next = next
        self.violation = violation
    }
}

/// A violation with the interleaving that reaches it, one line per step.
public struct Trace<Claim: Hashable & Sendable & CustomStringConvertible>: Sendable, CustomStringConvertible {
    public var claim: Claim
    public var message: String
    public var steps: [String]

    public init(claim: Claim, message: String, steps: [String]) {
        self.claim = claim
        self.message = message
        self.steps = steps
    }

    public var description: String {
        var s = "claim \(claim) violated: \(message)\n"
        for (i, step) in steps.enumerated() { s += "  \(i + 1). \(step)\n" }
        return s
    }
}

public struct Report<Claim: Hashable & Sendable & CaseIterable & CustomStringConvertible>: Sendable, CustomStringConvertible {
    /// Distinct states reached (violating states are not expanded).
    public var states: Int
    public var transitions: Int
    /// The largest number of steps from the start to any state on a shortest
    /// path: the longest trace breadth-first search produces.
    public var longestTrace: Int
    /// Runs that ended with every thread finished.
    public var finishedRuns: Int
    /// States the model counts as witnesses (`isWitness`).
    public var witnesses: Int
    public var seconds: Double
    /// The shortest violating trace per claim.
    public var violations: [Claim: Trace<Claim>]
    /// The shortest violating trace per distinct message, for a claim that
    /// can fail in more than one way.
    public var violationsByMessage: [String: Trace<Claim>] = [:]

    public init(states: Int, transitions: Int, longestTrace: Int, finishedRuns: Int, witnesses: Int,
                seconds: Double, violations: [Claim: Trace<Claim>], violationsByMessage: [String: Trace<Claim>]) {
        self.states = states
        self.transitions = transitions
        self.longestTrace = longestTrace
        self.finishedRuns = finishedRuns
        self.witnesses = witnesses
        self.seconds = seconds
        self.violations = violations
        self.violationsByMessage = violationsByMessage
    }

    public var description: String {
        var s = "\(states) states, \(transitions) transitions, longest trace \(longestTrace) steps, \(finishedRuns) finished states"
        if witnesses > 0 { s += ", \(witnesses) witness states" }
        s += ", \(String(format: "%.2f", seconds)) s"
        if violations.isEmpty { s += ", no violations" }
        for claim in Claim.allCases { if let t = violations[claim] { s += "\n" + t.description } }
        return s
    }
}

/// `@inlinable` so that each model's module specialises it: unspecialised,
/// the relocation model's largest configuration ran 1.8 times slower.
@inlinable
public func exploreModel<M: ExplorableModel>(_ model: M, stopAtFirstViolation: Bool = false) -> Report<M.Claim> {
    let start = Date()
    var states: [M.State] = [model.initialState()]
    var parent: [Int32] = [-1]
    var depth: [Int32] = [0]
    var seen: Set<UInt64> = [model.fingerprint(states[0])]
    var transitions = 0
    var finished = 0
    var witnesses = 0
    var violations: [M.Claim: Trace<M.Claim>] = [:]
    var byMessage: [String: Trace<M.Claim>] = [:]

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
        if model.isWitness(current) { witnesses += 1 }
        let steps = model.successors(current, labels: false)
        if steps.isEmpty {
            if let v = model.terminalViolation(current) {
                if byMessage[v.message] == nil {
                    let p = path(to: i)
                    let t = Trace(claim: v.claim, message: v.message, steps: labels(along: p) + ["(no step can follow)"])
                    byMessage[v.message] = t
                    if violations[v.claim] == nil { violations[v.claim] = t }
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
                if byMessage[v.message] == nil {
                    let p = path(to: i)
                    let last = model.successors(current, labels: true)[k].label
                    let t = Trace(claim: v.claim, message: v.message, steps: labels(along: p) + [last])
                    byMessage[v.message] = t
                    if violations[v.claim] == nil { violations[v.claim] = t }
                    if stopAtFirstViolation { break search }
                }
                continue
            }
            if seen.insert(model.fingerprint(step.next)).inserted {
                states.append(step.next)
                parent.append(Int32(i))
                depth.append(depth[i] + 1)
            }
        }
    }
    return Report(
        states: states.count, transitions: transitions,
        longestTrace: Int(depth.max() ?? 0), finishedRuns: finished, witnesses: witnesses,
        seconds: Date().timeIntervalSince(start), violations: violations, violationsByMessage: byMessage)
}
