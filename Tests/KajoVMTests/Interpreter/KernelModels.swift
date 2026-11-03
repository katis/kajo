import Testing

/// Swift models of the fixture kernels: what `run:of:` answers on worker
/// `w` of `n`. They are the independent oracle for the scaled-down kernel
/// runs in the debug test suite, and are themselves checked against the
/// published single-worker checksums.
enum KernelModel {
    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    static func checksum(_ name: String, w: Int64, n: Int64) -> Int64 {
        switch name {
        case "fib": return fib(w, n)
        case "arith": return arith(w, n)
        case "sends": return sends(w, n)
        case "alloc": return alloc(w, n)
        case "ivars": return ivars(w, n)
        case "walk": return walk(w, n)
        case "closures": return closures(w, n)
        case "floats": return floats(w, n)
        default: fatalError(name)
        }
    }

    /// Module 8's block-heavy kernel: per rep the inner sum of i \\ 7 over
    /// 1...1000 (2997) and the detected (rep \\ 1000) + 1.
    static func closures(_ w: Int64, _ n: Int64) -> Int64 {
        var reps = floorDiv(60_000, n), sum: Int64 = 0
        let inner = (1...1000).reduce(Int64(0)) { $0 + Int64($1 % 7) }
        while reps > 0 {
            sum += inner + reps % 1000 + 1
            reps -= 1
        }
        return sum
    }

    /// Module 8's SmallFloat kernel, in IEEE doubles as the VM computes it.
    static func floats(_ w: Int64, _ n: Int64) -> Int64 {
        let chunk = floorDiv(30_000_000, n)
        var x = 0.0
        var i = w * chunk
        while i < w * chunk + chunk {
            x = x * 0.999 + Double(i) * 0.25
            if !(x < 1.0e12) { x = x * 0.5 }
            i += 1
        }
        return Int64(x)
    }

    static func fibOf(_ k: Int64) -> Int64 { k < 2 ? k : fibOf(k - 1) + fibOf(k - 2) }

    static func fib(_ w: Int64, _ n: Int64) -> Int64 {
        var reps = floorDiv(96, n), sum: Int64 = 0
        var memo: [Int64: Int64] = [:]
        while reps > 0 {
            let k = 27 + reps % 2
            if memo[k] == nil { memo[k] = fibIter(k) }
            sum += memo[k]!
            reps -= 1
        }
        return sum
    }

    static func fibIter(_ k: Int64) -> Int64 {
        var a: Int64 = 0, b: Int64 = 1
        for _ in 0..<k { (a, b) = (b, a + b) }
        return a
    }

    static func arith(_ w: Int64, _ n: Int64) -> Int64 {
        let chunk = floorDiv(80_000_000, n), p: Int64 = 1_000_000_007
        var sum: Int64 = 0
        var i = w * chunk
        while i < w * chunk + chunk {
            sum += i * 3 + 7
            if sum >= p { sum -= p }
            i += 1
        }
        return sum
    }

    static func sends(_ w: Int64, _ n: Int64) -> Int64 {
        var reps = floorDiv(40_000_000, n), sum: Int64 = 0, k = w % 3 + 1
        while reps > 0 {
            switch k {
            case 1: sum += reps + 1     // Leaf (Adder)
            case 2: sum += reps + reps  // Doubler
            default: sum += reps - 3    // Subber
            }
            k += 1
            if k > 3 { k = 1 }
            reps -= 1
        }
        return sum
    }

    static func alloc(_ w: Int64, _ n: Int64) -> Int64 {
        floorDiv(320, n) * ((1 << 17) - 1) + ((1 << 13) - 1)
    }

    static func ivars(_ w: Int64, _ n: Int64) -> Int64 {
        let p: Int64 = 1_000_003
        var cells = (1...4).map { k -> [Int64] in let v = Int64(k) + w; return [v, v, v, 0] }
        var reps = floorDiv(32000, n), k = 0
        while reps > 0 {
            var c = cells[k]
            for _ in 0..<1000 {
                c[0] += c[1]; if c[0] >= p { c[0] -= p }
                c[2] += c[0]; if c[2] >= p { c[2] -= p }
                c[1] += 1; if !(c[1] < 1000) { c[1] = 0 }
                c[3] += 1
            }
            cells[k] = c
            k = (k + 1) % 4
            reps -= 1
        }
        return cells.reduce(0) { $0 + $1.reduce(0, +) }
    }

    static func walk(_ w: Int64, _ n: Int64) -> Int64 {
        let m = floorDiv(4_194_304, n)
        var next = [Int](repeating: 0, count: Int(m))
        for i in 0..<m { next[Int(i)] = Int((1_664_525 * i + 1_013_904_223) % m) }
        var sum: Int64 = 0
        for _ in 0..<2 {
            var p = 0
            for k in 1...m {
                sum &+= (Int64(p) % 1024 + 1) * k
                p = next[p]
            }
        }
        return sum
    }
}

/// The models reproduce the published checksums, so a scaled-down run that
/// matches its model is anchored to the experiments' results.
@Test(arguments: goldenKernels.map(\.name))
func kernelModelsReproduceThePublishedChecksums(_ name: String) {
    let published = goldenKernels.first { $0.name == name }!.checksum
    #expect(KernelModel.checksum(name, w: 0, n: 1) == published)
    if name == "fib" { #expect(KernelModel.fib(0, 96) == KernelModel.fibOf(28)) }
}
