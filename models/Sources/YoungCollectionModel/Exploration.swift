// The young-collection model on the shared explorer and memory model.

@_exported import ModelKit

public typealias Trace = ModelKit.Trace<Claim>
public typealias Report = ModelKit.Report<Claim>

public func explore(_ config: Configuration, stopAtFirstViolation: Bool = false) -> Report {
    exploreModel(Model(config), stopAtFirstViolation: stopAtFirstViolation)
}
