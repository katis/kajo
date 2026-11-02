import Testing
@testable import KajoVM

/// Mutations that keep kasm mostly well formed, so the checks after the
/// parser are reached too: flip a byte, replace a number, delete, duplicate
/// or swap lines, retarget an operand.
func mutateKasm(_ src: String, _ rng: inout SplitMix) -> String {
    var lines = src.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for _ in 0..<(1 + Int(rng.next() % 3)) {
        let i = Int(rng.next() % UInt64(lines.count))
        switch rng.next() % 6 {
        case 0:  // flip a bit of one byte
            var b = Array(lines[i].utf8)
            if !b.isEmpty {
                let k = Int(rng.next() % UInt64(b.count))
                b[k] ^= UInt8(truncatingIfNeeded: 1 << (rng.next() % 8))
                lines[i] = String(decoding: b, as: UTF8.self)
            }
        case 1:  // replace the last token with a number
            var t = lines[i].split(separator: " ").map(String.init)
            if !t.isEmpty {
                let pool: [Int64] = [0, 1, -1, 127, 128, -129, 255, 256, 4095, 4096, 32760, 1 << 62, Int64(rng.next() % 1000)]
                t[t.count - 1] = "\(pool[Int(rng.next() % UInt64(pool.count))])"
                lines[i] = t.joined(separator: " ")
            }
        case 2: lines.remove(at: i)
        case 3: lines.insert(lines[i], at: i)
        case 4: lines.swapAt(i, Int(rng.next() % UInt64(lines.count)))
        default:  // an operand from elsewhere in the file
            let j = Int(rng.next() % UInt64(lines.count))
            if let a = lines[i].split(separator: " ").first, let b = lines[j].split(separator: " ").last {
                lines[i] = "\(a) \(b)"
            }
        }
        if lines.isEmpty { lines = [""] }
    }
    return lines.joined(separator: "\n")
}

/// 3 000 seeded mutations of valid kasm either load (and leave a heap the
/// verifiers accept) or are rejected with a LoadError; none traps. The
/// same entry point is the libFuzzer target's.
@Test func mutatedKasmLoadsCleanOrIsRejected() {
    let seed = kernel("sends") + "\n" + kernel("prelude")
    var rng = SplitMix(seed: 7)
    var loaded = 0, rejected = 0
    for _ in 0..<3000 {
        if FuzzEntry.kasm(Array(mutateKasm(seed, &rng).utf8)) { loaded += 1 } else { rejected += 1 }
    }
    #expect(loaded > 300 && rejected > 1000)
}

@Test func theFuzzEntryPointsAcceptTheirSeeds() {
    #expect(FuzzEntry.kasm(Array(kernel("fib").utf8)))
    #expect(FuzzEntry.kasm(Array((kernel("prelude") + kernel("lib") + kernel("walk")).utf8)))
    #expect(FuzzEntry.snapshot(FuzzEntry.snapshotSeed()))
    #expect(!FuzzEntry.kasm([0xFF, 0xFE, 0x00, 0x0A]))
    #expect(!FuzzEntry.snapshot([1, 2, 3]))
}
