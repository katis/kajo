// Allocation pacing for Part 2 (SPEC.md "Part 2"): the main worker must
// allocate `rate` bytes per second, delivered at display-link ticks. Each
// tick asks how many objects are due since the start, minus those already
// allocated, capped at `maxFrames` frames' worth so a long stall does not
// turn into one huge frame. Pure arithmetic, tested on its own.

public struct Pacer: Sendable {
    public let bytesPerSecond: Double
    public let objectBytes: Int
    public let frameHz: Double
    public let maxFrames: Double
    public private(set) var issued: Int = 0
    public private(set) var capped: Int = 0
    public private(set) var start: Double? = nil

    public init(bytesPerSecond: Double, objectBytes: Int, frameHz: Double = 120, maxFrames: Double = 4) {
        self.bytesPerSecond = bytesPerSecond
        self.objectBytes = objectBytes
        self.frameHz = frameHz
        self.maxFrames = maxFrames
    }

    /// Objects one nominal frame allocates (rate / frameHz / objectBytes).
    public var perFrame: Double { bytesPerSecond / frameHz / Double(objectBytes) }

    /// Objects to allocate at time `t` (seconds, any monotonic origin).
    /// The first call starts the clock and is due one frame.
    public mutating func due(at t: Double) -> Int {
        guard let s = start else {
            start = t - 1 / frameHz
            return due(at: t)
        }
        let total = Int((t - s) * bytesPerSecond / Double(objectBytes))
        var n = max(0, total - issued)
        let cap = Int((perFrame * maxFrames).rounded(.up))
        if n > cap {
            capped += n - cap
            n = cap
            // Forget the debt beyond the cap: the rate is a target, the
            // measured rate is reported.
            issued = total - n
        }
        issued += n
        return n
    }
}
