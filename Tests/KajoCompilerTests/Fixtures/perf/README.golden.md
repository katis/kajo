# Kajo's performance

How fast Kajo's interpreter and collector are against runtimes a reader
knows, measured on one machine on one day. The prose is written by hand; every
number, table and graph between `generated` markers is written by
`scripts/perf-report.py` from the raw files and is never edited by hand.

<!-- generated: meta -->
Measured 2026-11-07 11:54 EET at commit `0459db7` on Apple M2 Pro, 8 P-cores + 4 E-cores, 32 GB, Mac14,12, macOS 27.2 (26B123); 1 interleaved rounds, every run bounded at 120 s; the time is the process's wall time.
<!-- /generated -->

## 0. What kind of VM this is

_Written by hand; see the module docs meanwhile._

## 1. How to read these numbers

Every runtime ran on the same machine on the same day, one program at a
time with nothing else of ours running. Each number is the median of five
rounds, and the rounds are interleaved: within a round every runtime runs the
kernel once before any runs it again, so a machine that warms up or slows
down over the session slows everyone alike; the first kernel is run once
more at the end to show how much it drifted. The time is the whole process's
wall time, start-up included for everyone, so the shortest runs are partly
start-up. Each program prints one checksum, and a run whose checksum differs
from the kernel's is refused and counts for nothing: every runtime in a table
did the same work, not merely a similar loop. Kajo is an interpreter with no
JIT, and it has to stay one, because iOS does not allow one; the runtimes
with a JIT are therefore also shown with it off (`luajit -joff`,
`node --jitless`, `java -Xint`, Ruby without `--yjit`), which is the
comparison with the most to say about Kajo's own design. C at `clang -O2` is
the floor. The parameters of every program and what each gap is made of are
in `experiments/runtime-comparison/RESULTS.md`.

## 2. Sends

<!-- generated: sends -->
**fib** (960 × fib(27 or 28), 798,757,440 calls per run)

![fib: recursive Fibonacci](fib.svg)

| runtime | median s | min–max s | spread | time against Kajo (kasm) | M calls/s |
|---|--:|--:|--:|--:|--:|
| Java (G1) | 0.101 | 0.101–0.101 | 0.0% | 0.06× | 7939.9 |
| LuaJIT | 0.149 | 0.149–0.149 | 0.0% | 0.09× | 5371.6 |
| Node (V8) | 0.214 | 0.214–0.214 | 0.0% | 0.12× | 3732.5 |
| C (clang -O2) | 0.230 | 0.230–0.230 | 0.0% | 0.13× | 3471.3 |
| Pharo 12 (Cog JIT) | 0.294 | 0.294–0.294 | 0.0% | 0.17× | 2718.7 |
| Ruby --yjit | 0.322 | 0.322–0.322 | 0.0% | 0.19× | 2482.9 |
| LuaJIT -joff | 0.661 | 0.661–0.661 | 0.0% | 0.38× | 1207.7 |
| Lua 5.4 | 1.30 | 1.30–1.30 | 0.0% | 0.75× | 615.8 |
| Ruby | 1.34 | 1.34–1.34 | 0.0% | 0.78× | 594.0 |
| Java -Xint | 1.69 | 1.69–1.69 | 0.0% | 0.98× | 473.6 |
| **Kajo (kasm)** | 1.73 | 1.73–1.73 | 0.0% | 1.00× | 462.6 |
| **Kajo (Smalltalk)** | 1.81 | 1.81–1.81 | 0.0% | 1.05× | 442.0 |
| CPython | 2.17 | 2.17–2.17 | 0.0% | 1.26× | 368.3 |
| Node --jitless | 2.21 | 2.21–2.21 | 0.0% | 1.28× | 362.2 |
| **Kajo (kasm), 8 workers (aggregate)** | 0.256 | 0.256–0.256 | 0.0% | 0.15× | 3126.3 |
| **Kajo (Smalltalk), 8 workers (aggregate)** | 0.313 | 0.313–0.313 | 0.0% | 0.18× | 2548.7 |

**dispatch** (100,000,000 sends over three classes plus an indexed read per run)

![dispatch: one polymorphic send site](dispatch.svg)

| runtime | median s | min–max s | spread | time against Kajo (kasm) | M sends/s |
|---|--:|--:|--:|--:|--:|
| LuaJIT | 0.048 | 0.048–0.048 | 0.0% | 0.02× | 2074.7 |
| Node (V8) | 0.120 | 0.120–0.120 | 0.0% | 0.05× | 836.1 |
| Java (G1) | 0.174 | 0.174–0.174 | 0.0% | 0.07× | 574.7 |
| C (clang -O2) | 0.246 | 0.246–0.246 | 0.0% | 0.09× | 406.0 |
| Pharo 12 (Cog JIT) | 0.339 | 0.339–0.339 | 0.0% | 0.13× | 295.3 |
| Java -Xint | 1.10 | 1.10–1.10 | 0.0% | 0.42× | 90.6 |
| LuaJIT -joff | 1.12 | 1.12–1.12 | 0.0% | 0.43× | 89.5 |
| Ruby --yjit | 1.56 | 1.56–1.56 | 0.0% | 0.59× | 64.2 |
| Lua 5.4 | 1.64 | 1.64–1.64 | 0.0% | 0.63× | 60.8 |
| Node --jitless | 1.77 | 1.77–1.77 | 0.0% | 0.68× | 56.4 |
| Ruby | 1.91 | 1.91–1.91 | 0.0% | 0.73× | 52.3 |
| **Kajo (Smalltalk)** | 2.36 | 2.36–2.36 | 0.0% | 0.90× | 42.3 |
| **Kajo (kasm)** | 2.62 | 2.62–2.62 | 0.0% | 1.00× | 38.1 |
| CPython | 6.79 | 6.79–6.79 | 0.0% | 2.59× | 14.7 |
| **Kajo (Smalltalk), 8 workers (aggregate)** | 0.382 | 0.382–0.382 | 0.0% | 0.15× | 262.1 |
| **Kajo (kasm), 8 workers (aggregate)** | 0.407 | 0.407–0.407 | 0.0% | 0.16× | 245.4 |
<!-- /generated -->

## 3. Allocation and collection

<!-- generated: allocation -->
**binarytrees** (one long-lived tree of depth 12, then 1280 trees of depth 16 built, checked and dropped: 167,779,071 objects per run)

![binarytrees](binarytrees.svg)

| runtime | median s | min–max s | spread | time against Kajo (kasm) | M objects/s |
|---|--:|--:|--:|--:|--:|
| Java (G1) | 0.200 | 0.200–0.200 | 0.0% | 0.07× | 837.6 |
| Java (ZGC) | 0.300 | 0.300–0.300 | 0.0% | 0.10× | 559.5 |
| Pharo 12 (Cog JIT) | 0.522 | 0.522–0.522 | 0.0% | 0.17× | 321.5 |
| C (clang -O2) | 0.748 | 0.748–0.748 | 0.0% | 0.25× | 224.4 |
| Node (V8) | 0.749 | 0.749–0.749 | 0.0% | 0.25× | 224.1 |
| LuaJIT | 1.57 | 1.57–1.57 | 0.0% | 0.52× | 107.1 |
| Java -Xint | 2.41 | 2.41–2.41 | 0.0% | 0.81× | 69.7 |
| LuaJIT -joff | 2.41 | 2.41–2.41 | 0.0% | 0.81× | 69.5 |
| Ruby --yjit | 2.78 | 2.78–2.78 | 0.0% | 0.93× | 60.3 |
| **Kajo (kasm)** | 2.99 | 2.99–2.99 | 0.0% | 1.00× | 56.1 |
| **Kajo (Smalltalk)** | 3.08 | 3.08–3.08 | 0.0% | 1.03× | 54.4 |
| Node --jitless | 3.51 | 3.51–3.51 | 0.0% | 1.17× | 47.8 |
| Ruby | 4.76 | 4.76–4.76 | 0.0% | 1.59× | 35.2 |
| Lua 5.4 | 5.34 | 5.34–5.34 | 0.0% | 1.79× | 31.4 |
| CPython | 9.46 | 9.46–9.46 | 0.0% | 3.17× | 17.7 |
| **Kajo (kasm), 8 workers (aggregate)** | 0.563 | 0.563–0.563 | 0.0% | 0.19× | 298.2 |
| **Kajo (Smalltalk), 8 workers (aggregate)** | 0.590 | 0.590–0.590 | 0.0% | 0.20× | 284.5 |

Collector pauses where the runtime reports them (medians over the rounds of each run's own percentiles; Kajo's pauses are its stops, its young collections on one worker run on the program's own thread; the JVM's from `-Xlog:gc`; Pharo reports only counts and totals):

| runtime | collections per run | pause p50 ms | pause p99 ms | pause max ms | Kajo's own young collections p50 / p99 ms |
|---|--:|--:|--:|--:|--:|
| Java (G1) | 4 pauses | 0.546 | 1.115 | 1.115 | - |
| Java (ZGC) | 5 pauses | 0.005 | 0.006 | 0.006 | - |
| Pharo 12 (Cog JIT) | 65 scavenges, 0 full (0 ms) | 0.738 (mean) | - | - | - |
| Java -Xint | 4 pauses | 0.593 | 0.983 | 0.983 | - |
| Kajo (kasm) | 320 young, 9 stops | 0.113 | 0.264 | 0.264 | 1.673 / 1.911 |
| Kajo (Smalltalk) | 320 young, 9 stops | 0.103 | 0.297 | 0.297 | 1.684 / 1.961 |
| Kajo (kasm), 8 workers (aggregate) | 320 young, 6 stops | 0.248 | 21.304 | 21.304 | 2.499 / 19.155 |
| Kajo (Smalltalk), 8 workers (aggregate) | 320 young, 6 stops | 0.291 | 22.812 | 22.812 | 2.588 / 4.964 |
<!-- /generated -->

## 4. Bytecodes

<!-- generated: bytecodes -->
**arith** (320,000,000 iterations of `sum := sum + (i * 3 + 7)`, a conditional subtract of 1000000007; in Kajo's kasm 7,334,400,000 bytecodes per run)

![arith](arith.svg)

| runtime | median s | min–max s | spread | time against Kajo (kasm) | M iterations/s |
|---|--:|--:|--:|--:|--:|
| LuaJIT | 0.092 | 0.092–0.092 | 0.0% | 0.04× | 3467.0 |
| Java (G1) | 0.099 | 0.099–0.099 | 0.0% | 0.04× | 3232.3 |
| Node (V8) | 0.127 | 0.127–0.127 | 0.0% | 0.05× | 2521.7 |
| C (clang -O2) | 0.262 | 0.262–0.262 | 0.0% | 0.10× | 1221.4 |
| Pharo 12 (Cog JIT) | 0.395 | 0.395–0.395 | 0.0% | 0.15× | 810.1 |
| LuaJIT -joff | 1.26 | 1.26–1.26 | 0.0% | 0.49× | 254.8 |
| Lua 5.4 | 1.29 | 1.29–1.29 | 0.0% | 0.50× | 247.4 |
| Node --jitless | 1.45 | 1.45–1.45 | 0.0% | 0.56× | 220.7 |
| Java -Xint | 1.57 | 1.57–1.57 | 0.0% | 0.61× | 203.7 |
| Ruby --yjit | 1.85 | 1.85–1.85 | 0.0% | 0.72× | 173.3 |
| Ruby | 1.85 | 1.85–1.85 | 0.0% | 0.72× | 173.0 |
| **Kajo (Smalltalk)** | 2.49 | 2.49–2.49 | 0.0% | 0.97× | 128.4 |
| **Kajo (kasm)** | 2.57 | 2.57–2.57 | 0.0% | 1.00× | 124.5 |
| CPython | 9.75 | 9.75–9.75 | 0.0% | 3.79× | 32.8 |

Kajo (kasm) runs 2874 M bytecodes/s in its own kernel time (2.55 s of the 2.57 s process).
<!-- /generated -->

## 5. The Smalltalk library against Pharo

<!-- generated: library -->
**collections** (three times: an OrderedCollection of a million SmallIntegers filled and summed with `do:` and `inject:into:`; a Dictionary of 200 000 Symbol keys built and looked up; a String of a million characters built with a WriteStream and scanned; 500 000 SmallIntegers sorted; the same source in both)

![collections](collections.svg)

| runtime | median s | min–max s | spread | time against Kajo (Smalltalk) |
|---|--:|--:|--:|--:|
| Pharo 12 (Cog JIT) | 1.66 | 1.66–1.66 | 0.0% | 0.23× |
| **Kajo (Smalltalk)** | 7.11 | 7.11–7.11 | 0.0% | 1.00× |
<!-- /generated -->

## 6. Scaling across workers

<!-- generated: scaling -->
![scaling](scaling.svg)

| runtime | kernel | 1 worker s | 8 workers s | speedup |
|---|---|--:|--:|--:|
| Kajo (kasm) | fib | 1.73 | 0.256 | 6.76× |
| Kajo (Smalltalk) | fib | 1.81 | 0.313 | 5.77× |
| Kajo (kasm) | dispatch | 2.62 | 0.407 | 6.44× |
| Kajo (Smalltalk) | dispatch | 2.36 | 0.382 | 6.20× |
| Kajo (kasm) | binarytrees | 2.99 | 0.563 | 5.31× |
| Kajo (Smalltalk) | binarytrees | 3.08 | 0.590 | 5.22× |
<!-- /generated -->

The language experiment's Rust and Swift slices (`just bench`,
`experiments/vm-language-bench`), the evidence ADR 0001 rests on: the same
kasm kernels at their original sizes on a minimal VM, not Kajo's core.

<!-- generated: slices -->
From machine: Apple M2 Max, 8 P-cores + 4 E-cores, no pinning.

| kernel | variant | 1 worker ms | 8 workers ms | speedup |
|---|---|--:|--:|--:|
| arith | rust | 3004.1 | 407.3 | 7.38× |
| arith | rust-native | 3007.1 | 402.1 | 7.48× |
| arith | swift-O | 3627.6 | 483.1 | 7.51× |
| arith | swift-Ounchecked | 3078.7 | 415.1 | 7.42× |
| arith | rust-align32 | 2999.2 | 403.8 | 7.43× |
| arith | swift-O-align32 | 3039.8 | 413.0 | 7.36× |
| fib | rust | 1469.9 | 189.7 | 7.75× |
| fib | rust-native | 1468.6 | 200.9 | 7.31× |
| fib | swift-O | 1924.3 | 251.0 | 7.67× |
| fib | swift-Ounchecked | 1543.9 | 203.7 | 7.58× |
| fib | rust-align32 | 1473.8 | 196.2 | 7.51× |
| fib | swift-O-align32 | 1561.2 | 213.5 | 7.31× |
| sends | rust | 2388.0 | 432.2 | 5.53× |
| sends | rust-native | 2387.0 | 390.3 | 6.12× |
| sends | swift-O | 2938.8 | 521.0 | 5.64× |
| sends | swift-Ounchecked | 2576.3 | 442.4 | 5.82× |
| sends | rust-align32 | 2383.9 | 397.8 | 5.99× |
| sends | swift-O-align32 | 2610.2 | 448.2 | 5.82× |
| alloc | rust | 2014.9 | 468.3 | 4.30× |
| alloc | rust-native | 2015.6 | 463.0 | 4.35× |
| alloc | swift-O | 2375.5 | 516.1 | 4.60× |
| alloc | swift-Ounchecked | 2069.7 | 486.9 | 4.25× |
| alloc | rust-align32 | 2009.0 | 466.9 | 4.30× |
| alloc | swift-O-align32 | 2111.4 | 486.1 | 4.34× |
<!-- /generated -->

## 7. On the devices

<!-- generated: devices -->
| device rows | scenario | young | frames missed of expected | main stopped for others ms/10 s | launches | thermal at end |
|---|---|---|--:|--:|--:|---|
| fixture-phone | storm | offload | 1 of 1200 | 50 | 2 | fair,serious |
| fixture-phone | ring | stw | 1 of 1200 | 1250 | 1 | serious |
<!-- /generated -->

## 8. Caveats

<!-- generated: caveats -->
- Runtimes missing from this run: none.
- Thermal state at the runs' starts: fair 1, nominal 81 runs.
- Refused runs (1, not in any number above): python arith w1 round 1 (timeout, checksum -).
- Spread of the medians ((max − min) / median over each row's 1 rounds): at most 0.0% (Ruby --yjit, fib); all 65 rows within 5%.
- Drift: the first kernel (fib) run again at the end took 0.356 to 1.018 times its median (C (clang -O2) to Node (V8)).
- Every time is the whole process's wall time, start-up included for every runtime alike (Kajo loads its image or assembles its kasm, the JVM and Pharo start their VMs); a run of a few hundred milliseconds is mostly start-up.
<!-- /generated -->

## 9. Reproducing

`just perf` runs the comparison (`experiments/runtime-comparison/bench.sh`,
about an hour), then `just bench`, then regenerates this file and its graphs;
`just perf-report` regenerates them from the raw files alone. The runtimes are
Homebrew's (`brew install lua luajit openjdk ruby`, Node from the machine's
own install) and Pharo 12 from its zeroconf download into
`experiments/runtime-comparison/pharo/`. Versions of this run:

<!-- generated: versions -->
| runtime | version |
|---|---|
| Kajo (kasm) | 0459db7 release -enable-testing aligned, Swift 6.4.2 |
| Kajo (Smalltalk) | 0459db7 release -enable-testing aligned, Swift 6.4.2 |
| Pharo 12 (Cog JIT) | Pharo12.0.0SNAPSHOT / v10.3.12+0.4b0622446 - Commit: 4b0622446 - Date: 2026-10-23 12:16:05 +0200 |
| C (clang -O2) | Apple clang version 21.0.0 (clang-2100.4.1.1), -O2 |
| LuaJIT | LuaJIT 2.1.1710088188 |
| LuaJIT -joff | LuaJIT 2.1.1710088188 |
| Lua 5.4 | Lua 5.4.6 |
| Node (V8) | Node v24.5.0 (V8 13.6.233.10-node.21) |
| Node --jitless | Node v24.5.0 (V8 13.6.233.10-node.21) |
| Java (G1) | OpenJDK Runtime Environment Homebrew (build 21.0.2) |
| Java -Xint | OpenJDK Runtime Environment Homebrew (build 21.0.2) |
| Java (ZGC) | OpenJDK Runtime Environment Homebrew (build 21.0.2) |
| Ruby | ruby 3.3.0 |
| Ruby --yjit | ruby 3.3.0 |
| CPython | Python 3.12.2 |

Raw files: `Tests/KajoCompilerTests/Fixtures/perf/bench-raw.txt` (1 rounds) and `Tests/KajoCompilerTests/Fixtures/perf/slices-raw.txt`.
<!-- /generated -->
