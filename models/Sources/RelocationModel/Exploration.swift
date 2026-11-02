// The relocation model on the shared explorer and memory model (ModelKit).

@_exported import ModelKit

public typealias Violation = ModelKit.Violation<Claim>
public typealias Trace = ModelKit.Trace<Claim>
public typealias Report = ModelKit.Report<Claim>
typealias Step = Transition<State, Claim>

extension Model: ExplorableModel {
    func fingerprint(_ s: State) -> UInt64 { s.fingerprint() }
}

public func explore(_ config: Configuration, stopAtFirstViolation: Bool = false) -> Report {
    exploreModel(Model(config), stopAtFirstViolation: stopAtFirstViolation)
}
