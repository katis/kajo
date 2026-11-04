import Foundation

/// Launch arguments in the experiments' `key=value` form (`mode=scenario
/// scenario=storm young=offload workers=5 seconds=10`); other arguments
/// (Xcode's, `-NSDocumentRevisionsDebugMode`) are ignored.
public struct LaunchOptions: Sendable {
    public var values: [String: String] = [:]

    public init(_ arguments: [String] = CommandLine.arguments) {
        for a in arguments.dropFirst() {
            guard let eq = a.firstIndex(of: "="), !a.hasPrefix("-") else { continue }
            values[String(a[..<eq])] = String(a[a.index(after: eq)...])
        }
    }

    public subscript(_ key: String) -> String? { values[key] }
    public func string(_ key: String, _ d: String) -> String { values[key] ?? d }
    public func int(_ key: String, _ d: Int) -> Int { values[key].flatMap { Int($0) } ?? d }
    public func double(_ key: String, _ d: Double) -> Double { values[key].flatMap { Double($0) } ?? d }
    public var mode: String { values["mode"] ?? "demo" }

    /// The arguments as one `key=value ...` string, sorted.
    public var summary: String { values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: " ") }
}
