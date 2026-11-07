# Kajo's performance

How fast Kajo's interpreter and collector are against runtimes a reader
knows, measured on one machine on one day. The prose is written by hand; every
number, table and graph between `generated` markers is written by
`scripts/perf-report.py` from the raw files and is never edited by hand.

<!-- generated: meta -->
Measured 2026-11-07 19:34 EET at commit `e2dac1f` on Apple M2 Pro, 8 P-cores + 4 E-cores, 32 GB, Mac14,12, macOS 27.2 (26B123); 5 interleaved rounds, every run bounded at 120 s; the time is the process's wall time.
<!-- /generated -->

## 0. What kind of VM this is

Kajo is a Smalltalk virtual machine written in Swift (ADR 0001) that runs
the same on macOS and iOS. iOS forbids a JIT, so Kajo is an **interpreter
by design, not as a first step**: every number in this report is bytecode
interpretation, and the runtimes it is compared with are shown both with
their JIT and, where they have one, with it turned off, because the second
figure is the one Kajo can be held to on a phone. The design question the
VM answers is not "how fast can Smalltalk run" but "how fast can it run
while a 120 Hz user interface on the same heap never waits for it".

**Execution.** A stack bytecode set (v1, ADR 0009: 50 opcodes with an
`ext` prefix, special sends for arithmetic and comparison, compiled closures
with temp vectors, Contexts materialized only when something reflects on a
frame) runs through one `switch` that compiles to a single jump table and a
single indirect branch, which `just arc-check` asserts on the release
disassembly. The interpreter's state is a struct in raw memory passed as
scalars; there is no reference counting, no existential and no class on the
dispatch, send, primitive or allocation paths. Sends go through a per-worker
direct-mapped method cache keyed by class and selector; since the
interpreter-speed module (`docs/modules/interpreter-speed.md`) the loader
fuses the 17 most frequent opcode pairs into one instruction each (the
fused opcode replaces the first pair member's byte only, so offsets and
the source map are the plain code's) and `at:`, `isNil` and `notNil` run
inline; there are no per-site inline caches (a build that trusted the
cache line without comparing put their ceiling at 2 percent, so none was
built) and no register bytecode. On the same kernels the Swift VM runs
within 1 to 8 percent of a Rust implementation of the same design
(`experiments/vm-language-bench/RESULTS.md`). Smalltalk Processes run on OS
threads, several at once, over one shared heap: the kernels below report one
worker and eight, and the eight-worker rows are real parallelism, not time
slicing.

**Object representation.** Objects are reached through an **object table**
(ADR 0003): a reference is an index into a table of entries, and the entry
holds the body's address. This costs about 2x per cache-missing hop and 1.8
to 2x in marking time against direct pointers, measured on both the Mac and
the phone before the decision was made, and it buys the one thing the rest
of the design rests on: an object can be moved by changing one word, so
compaction and relocation run concurrently with the program and the
interpreter never holds a raw body pointer it has not pinned. SmallIntegers,
SmallFloats and Characters are immediates and never touch the table.
Objects past one 32 KiB block live in a large-object space of block runs
that are never moved (module 10); byte objects may be 2 GiB - 1 long.

**Memory management.** Generational, with a **nursery per worker** (ADR
0005): allocation is a bump of a thread-local pointer, and a young
collection copies survivors with an age field into survivor spaces before
promoting them. Old space is collected by a **concurrent marker** with a
snapshot-at-the-beginning barrier and a **lazy sweep** (ADR 0006), and
compacted by **concurrent relocation** through the entry table (ADR 0007):
old-space work happens on collector threads while Processes run, and the
program stops only for the collector's handshakes. The young generation is
collected **without stopping the world** (ADR 0008): a background worker
collects its own nursery while the others run, and the main thread's
nursery is collected by a collector thread on its behalf, so the main
thread's stops are acknowledgements of 28 to 44 µs rather than copies. Stop
times are measured from the request and recorded per stop kind; on the
iPhone 13 Pro and the iPad Pro every stop kind stays under 1.1 ms in every
launch of the allocation storm, and the main thread misses no frame under
the shells' default mode at 5 workers (`docs/modules/final-mark.md`).

**The user interface.** Smalltalk UI code runs on the main thread under
**budgeted preemption** (ADR 0004): a turn of Smalltalk on the main thread
is given a slice of the frame and preempted at its next poll when the slice
is spent, so a runaway loop in UI code costs frames in the shell's logs, not
a frozen app. The native views are AppKit and UIKit wrappers reached through
one primitive, and no object reference crosses to the host side (module 9a).

**Safety.** The VM core builds with Swift's strict memory safety on, so
every unsafe construct is written down and countable; ThreadSanitizer runs
as a gate, not a report; the stop-the-world collector is kept as an oracle
every random program is checked against; the concurrent protocols (relocation,
young collection, the image save) have exhaustive interleaving models
(`docs/models/`); the image loader, the assembler, the compiler's parser and
the development protocol each have a libFuzzer target. A method installed
from Smalltalk goes through the one bytecode verifier the image build uses,
so a program cannot make the interpreter execute what the verifier has not
seen.

**What the choices cost, measured.** The object table's hop and marking
costs above; the SATB barrier 1.4 percent on an instance-variable kernel
with marking off; the relocation post-store check within noise on the hot
kernels and 5 to 10 percent on cache-missing stores; the read-only bit's
header test about two cycles per store (7 to 10 percent on a kernel that
does nothing but store); a global method cache that is flushed at every
pause; frames with five header words whose code and literal bases are
re-derived through the table on every activation and return. The first
three are the price of a UI thread that does not wait; the last two were
the interpreter-speed module's targets, and it measured both and left
them: trusting the cache line without comparing bought under 2 percent,
and a leaner activation won 8 percent on fib alone but spilled two
registers and lost 6 to 8 on the arithmetic and instance-variable
kernels. The 18 to 39 percent it recovered came from fused instructions
instead (section 1a).

**What is not here.** No JIT and no ahead-of-time compilation (a later
module may compile release images ahead of time); no polymorphic inline
caches; the kernel's collections are unsynchronized Smalltalk code, not
primitives, so the library comparison against Pharo in section 5 compares
two Smalltalk libraries on two interpreters, with Pharo's Cog running a
JIT. Where a gap below is a JIT's, a register bytecode's or an inline
cache's, the paragraph under the table says so with the evidence it has;
where it does not know, it says that.

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

### 1a. Before and after the interpreter-speed module

The tables below are the run after the interpreter-speed module. The
baseline run of the same day at commit `01767ab`, before it, is kept
as `experiments/runtime-comparison/bench-raw-before-interpreter.txt`;
`scripts/perf-report.py --raw <that file>` regenerates its tables.
Between the two runs every other runtime repeated its median within
1 percent (CPython within 4, Ruby `--yjit` on binarytrees within 3),
so what moved is Kajo's interpreter:

| program (one worker) | before, s | after, s | after / before |
|---|--:|--:|--:|
| fib, kasm | 17.0 | 13.9 | 0.82 |
| fib, Smalltalk | 17.7 | 14.6 | 0.83 |
| dispatch, kasm | 6.56 | 4.19 | 0.64 |
| dispatch, Smalltalk | 5.83 | 3.55 | 0.61 |
| arith, kasm | 10.9 | 8.01 | 0.74 |
| arith, Smalltalk | 10.6 | 8.03 | 0.76 |
| binarytrees, kasm | 11.8 | 11.5 | 0.97 |
| binarytrees, Smalltalk | 12.0 | 11.8 | 0.98 |
| collections, Smalltalk | 7.10 | 6.25 | 0.88 |
| 8 workers: fib / dispatch / binarytrees, kasm | 2.29 / 0.906 / 1.93 | 1.89 / 0.590 / 1.88 | 0.83 / 0.65 / 0.98 |

The module's own A/B on the VM's kernels (`docs/modules/interpreter-speed.md`)
attributes the change: the fused pairs cut dispatches to 0.62 to 0.84 of
the plain count and cycles per send on the send kernels to 0.61 to 0.82,
and the inline `at:`, `isNil` and `notNil` took a further 11 percent off
the Smalltalk send kernel.

Read against the field: on fib Kajo moved from level with Java `-Xint`
to 15 percent ahead of it and within 9 percent of Lua 5.4 and Ruby; on
dispatch from behind every interpreter but CPython to level with Lua
5.4 and ahead of Node `--jitless` and Ruby (the Smalltalk program ahead
of Ruby `--yjit`); on arith from behind every interpreter but CPython
to within 3 percent of Ruby, with Java `-Xint`, Node `--jitless` and
Lua 5.4 still 16, 25 and 30 percent faster. LuaJIT's hand-written interpreter stays 1.5 to 2.1 times
faster on the three (2.3 to 2.6 before); the allocation kernel did not
move, because it is the collector's. The kernel's collections against
Pharo went from 4.3 to 3.8 times; the rest of that gap is the library
(section 5), not the interpreter.

## 2. Sends

<!-- generated: sends -->
**fib** (960 × fib(27 or 28), 798,757,440 calls per run)

![fib: recursive Fibonacci](fib.svg)

| runtime | median s | min–max s | spread | time against Kajo (kasm) | M calls/s |
|---|--:|--:|--:|--:|--:|
| Java (G1) | 0.681 | 0.674–0.687 | 2.0% | 0.05× | 1172.1 |
| C (clang -O2) | 0.715 | 0.712–0.717 | 0.7% | 0.05× | 1117.8 |
| LuaJIT | 1.39 | 1.33–1.43 | 7.6% | 0.10× | 576.7 |
| Node (V8) | 1.83 | 1.83–1.83 | 0.3% | 0.13× | 436.3 |
| Pharo 12 (Cog JIT) | 2.30 | 2.29–2.31 | 0.8% | 0.17× | 347.2 |
| Ruby --yjit | 2.81 | 2.81–2.82 | 0.3% | 0.20× | 283.9 |
| LuaJIT -joff | 6.52 | 6.50–6.53 | 0.4% | 0.47× | 122.5 |
| Ruby | 12.7 | 12.7–12.8 | 1.1% | 0.91× | 62.9 |
| Lua 5.4 | 12.8 | 12.8–12.8 | 0.2% | 0.92× | 62.4 |
| **Kajo (kasm)** | 13.9 | 13.9–14.0 | 1.1% | 1.00× | 57.4 |
| **Kajo (Smalltalk)** | 14.6 | 14.6–14.6 | 0.2% | 1.05× | 54.7 |
| Java -Xint | 16.4 | 16.3–16.5 | 1.0% | 1.18× | 48.6 |
| CPython | 21.5 | 21.4–21.6 | 0.8% | 1.54× | 37.2 |
| Node --jitless | 21.7 | 21.5–21.9 | 1.7% | 1.56× | 36.9 |
| **Kajo (kasm), 8 workers (aggregate)** | 1.89 | 1.89–1.90 | 0.8% | 0.14× | 421.9 |
| **Kajo (Smalltalk), 8 workers (aggregate)** | 2.00 | 2.00–2.01 | 0.7% | 0.14× | 399.5 |

**dispatch** (100,000,000 sends over three classes plus an indexed read per run)

![dispatch: one polymorphic send site](dispatch.svg)

| runtime | median s | min–max s | spread | time against Kajo (kasm) | M sends/s |
|---|--:|--:|--:|--:|--:|
| LuaJIT | 0.106 | 0.103–0.113 | 8.9% | 0.03× | 944.3 |
| Node (V8) | 0.248 | 0.244–0.251 | 2.9% | 0.06× | 402.6 |
| C (clang -O2) | 0.253 | 0.250–0.256 | 2.3% | 0.06× | 394.9 |
| Java (G1) | 0.380 | 0.372–0.381 | 2.3% | 0.09× | 263.2 |
| Pharo 12 (Cog JIT) | 0.744 | 0.731–0.750 | 2.4% | 0.18× | 134.3 |
| Java -Xint | 2.70 | 2.70–2.71 | 0.6% | 0.64× | 37.0 |
| LuaJIT -joff | 2.77 | 2.76–2.84 | 2.7% | 0.66× | 36.2 |
| **Kajo (Smalltalk)** | 3.55 | 3.55–3.55 | 0.3% | 0.85× | 28.1 |
| Ruby --yjit | 3.81 | 3.79–3.81 | 0.7% | 0.91× | 26.2 |
| **Kajo (kasm)** | 4.19 | 4.18–4.20 | 0.5% | 1.00× | 23.9 |
| Lua 5.4 | 4.21 | 4.08–4.26 | 4.2% | 1.00× | 23.8 |
| Node --jitless | 4.45 | 4.43–4.49 | 1.3% | 1.06× | 22.5 |
| Ruby | 4.63 | 4.62–4.71 | 2.0% | 1.10× | 21.6 |
| CPython | 18.6 | 17.3–19.7 | 12.9% | 4.42× | 5.4 |
| **Kajo (Smalltalk), 8 workers (aggregate)** | 0.534 | 0.516–0.539 | 4.2% | 0.13× | 187.2 |
| **Kajo (kasm), 8 workers (aggregate)** | 0.590 | 0.580–0.614 | 5.8% | 0.14× | 169.5 |
<!-- /generated -->

## 3. Allocation and collection

<!-- generated: allocation -->
**binarytrees** (one long-lived tree of depth 12, then 1280 trees of depth 16 built, checked and dropped: 167,779,071 objects per run)

![binarytrees](binarytrees.svg)

| runtime | median s | min–max s | spread | time against Kajo (kasm) | M objects/s |
|---|--:|--:|--:|--:|--:|
| Java (G1) | 0.592 | 0.574–0.595 | 3.6% | 0.05× | 283.5 |
| Java (ZGC) | 0.949 | 0.926–1.02 | 10.1% | 0.08× | 176.9 |
| Pharo 12 (Cog JIT) | 1.90 | 1.89–1.91 | 0.9% | 0.17× | 88.4 |
| C (clang -O2) | 2.47 | 2.45–2.47 | 0.8% | 0.22× | 68.0 |
| Node (V8) | 2.80 | 2.79–2.85 | 2.1% | 0.24× | 60.0 |
| LuaJIT | 6.24 | 6.20–6.31 | 1.7% | 0.54× | 26.9 |
| Java -Xint | 9.34 | 9.33–9.34 | 0.2% | 0.82× | 18.0 |
| LuaJIT -joff | 9.63 | 9.59–9.68 | 0.9% | 0.84× | 17.4 |
| Ruby --yjit | 10.9 | 10.9–11.2 | 2.5% | 0.96× | 15.3 |
| **Kajo (kasm)** | 11.5 | 11.4–11.6 | 2.0% | 1.00× | 14.6 |
| **Kajo (Smalltalk)** | 11.8 | 11.8–11.9 | 1.0% | 1.03× | 14.2 |
| Node --jitless | 14.0 | 13.9–14.0 | 0.6% | 1.22× | 12.0 |
| Ruby | 18.8 | 18.6–18.9 | 1.5% | 1.64× | 8.9 |
| Lua 5.4 | 21.3 | 21.2–21.3 | 0.7% | 1.86× | 7.9 |
| CPython | 37.9 | 37.8–37.9 | 0.3% | 3.31× | 4.4 |
| **Kajo (kasm), 8 workers (aggregate)** | 1.88 | 1.88–1.91 | 1.8% | 0.16× | 89.3 |
| **Kajo (Smalltalk), 8 workers (aggregate)** | 1.94 | 1.92–1.98 | 2.8% | 0.17× | 86.7 |

Collector pauses where the runtime reports them (medians over the rounds of each run's own percentiles; Kajo's pauses are its stops, its young collections on one worker run on the program's own thread; the JVM's from `-Xlog:gc`; Pharo reports only counts and totals):

| runtime | collections per run | pause p50 ms | pause p99 ms | pause max ms | Kajo's own young collections p50 / p99 ms |
|---|--:|--:|--:|--:|--:|
| Java (G1) | 12 pauses | 0.691 | 1.077 | 1.077 | - |
| Java (ZGC) | 15 pauses | 0.005 | 0.007 | 0.007 | - |
| Pharo 12 (Cog JIT) | 260 scavenges, 0 full (0 ms) | 0.688 (mean) | - | - | - |
| Java -Xint | 14 pauses | 0.619 | 0.983 | 0.983 | - |
| Kajo (kasm) | 1280 young, 36 stops | 0.089 | 0.319 | 0.319 | 1.641 / 1.884 |
| Kajo (Smalltalk) | 1280 young, 36 stops | 0.095 | 0.276 | 0.276 | 1.636 / 1.893 |
| Kajo (kasm), 8 workers (aggregate) | 1280 young, 30 stops | 0.222 | 30.045 | 30.045 | 2.154 / 4.390 |
| Kajo (Smalltalk), 8 workers (aggregate) | 1280 young, 31 stops | 0.219 | 23.594 | 23.594 | 2.161 / 4.280 |
<!-- /generated -->

The 19 to 30 ms stops in Kajo's 8-worker rows are seven stops a run of the
kind the large-bytes follow-up added: an allocation that finds the entry
table empty finishes the lazy sweep in a stop of its own (`sweepsForEntries`,
42 ms of sweeping in stops over a 1.8 s run) instead of falling back to a
full collection. On one worker the same program's longest stop is 0.33 ms.
The run line's `stopsByKind` files these under `other` today; naming the
kind and bounding the stop (apply what is swept, wait for the rest with the
world running) is a collector follow-up listed in `docs/PLAN.md`. Every other stop kind in these runs is
under 0.4 ms.

## 4. Bytecodes

<!-- generated: bytecodes -->
**arith** (320,000,000 iterations of `sum := sum + (i * 3 + 7)`, a conditional subtract of 1000000007; in Kajo's kasm 7,334,400,000 bytecodes per run)

![arith](arith.svg)

| runtime | median s | min–max s | spread | time against Kajo (kasm) | M iterations/s |
|---|--:|--:|--:|--:|--:|
| Java (G1) | 0.282 | 0.278–0.290 | 4.4% | 0.04× | 1135.6 |
| LuaJIT | 0.407 | 0.401–0.414 | 3.1% | 0.05× | 786.0 |
| C (clang -O2) | 0.411 | 0.400–0.425 | 6.1% | 0.05× | 778.8 |
| Node (V8) | 0.421 | 0.417–0.429 | 3.0% | 0.05× | 759.9 |
| Pharo 12 (Cog JIT) | 1.48 | 1.47–1.49 | 1.2% | 0.18× | 216.6 |
| LuaJIT -joff | 4.72 | 4.71–4.73 | 0.4% | 0.59× | 67.8 |
| Lua 5.4 | 5.61 | 5.60–5.62 | 0.4% | 0.70× | 57.0 |
| Node --jitless | 6.02 | 5.97–6.03 | 1.0% | 0.75× | 53.2 |
| Java -Xint | 6.77 | 6.73–6.77 | 0.7% | 0.84× | 47.3 |
| Ruby --yjit | 7.79 | 7.76–7.80 | 0.5% | 0.97× | 41.1 |
| Ruby | 7.80 | 7.78–7.83 | 0.6% | 0.97× | 41.0 |
| **Kajo (kasm)** | 8.01 | 8.00–8.02 | 0.2% | 1.00× | 40.0 |
| **Kajo (Smalltalk)** | 8.03 | 8.01–8.05 | 0.6% | 1.00× | 39.8 |
| CPython | 46.4 | 44.9–51.8 | 14.9% | 5.79× | 6.9 |

Kajo (kasm) runs 918 M bytecodes/s in its own kernel time (7.99 s of the 8.01 s process).
<!-- /generated -->

## 5. The Smalltalk library against Pharo

<!-- generated: library -->
**collections** (three times: an OrderedCollection of a million SmallIntegers filled and summed with `do:` and `inject:into:`; a Dictionary of 200 000 Symbol keys built and looked up; a String of a million characters built with a WriteStream and scanned; 500 000 SmallIntegers sorted; the same source in both)

![collections](collections.svg)

| runtime | median s | min–max s | spread | time against Kajo (Smalltalk) |
|---|--:|--:|--:|--:|
| Pharo 12 (Cog JIT) | 1.63 | 1.62–1.64 | 1.7% | 0.26× |
| **Kajo (Smalltalk)** | 6.25 | 6.23–6.27 | 0.6% | 1.00× |
<!-- /generated -->

## 6. Scaling across workers

<!-- generated: scaling -->
![scaling](scaling.svg)

| runtime | kernel | 1 worker s | 8 workers s | speedup |
|---|---|--:|--:|--:|
| Kajo (kasm) | fib | 13.9 | 1.89 | 7.35× |
| Kajo (Smalltalk) | fib | 14.6 | 2.00 | 7.31× |
| Kajo (kasm) | dispatch | 4.19 | 0.590 | 7.11× |
| Kajo (Smalltalk) | dispatch | 3.55 | 0.534 | 6.65× |
| Kajo (kasm) | binarytrees | 11.5 | 1.88 | 6.10× |
| Kajo (Smalltalk) | binarytrees | 11.8 | 1.94 | 6.09× |
<!-- /generated -->

The language experiment's Rust and Swift slices (`just bench`,
`experiments/vm-language-bench`), the evidence ADR 0001 rests on: the same
kasm kernels at their original sizes on a minimal VM, not Kajo's core.

<!-- generated: slices -->
From machine: Apple M2 Pro, 8 P-cores + 4 E-cores, no pinning.

| kernel | variant | 1 worker ms | 8 workers ms | speedup |
|---|---|--:|--:|--:|
| arith | rust | 3011.1 | 416.4 | 7.23× |
| arith | rust-native | 2993.1 | 408.1 | 7.33× |
| arith | swift-O | 3050.7 | 426.6 | 7.15× |
| arith | swift-Ounchecked | 3057.0 | 416.0 | 7.35× |
| arith | rust-align32 | 3006.9 | 413.2 | 7.28× |
| arith | swift-O-align32 | 3057.5 | 417.0 | 7.33× |
| fib | rust | 1465.8 | 209.1 | 7.01× |
| fib | rust-native | 1464.1 | 200.6 | 7.30× |
| fib | swift-O | 1538.4 | 214.3 | 7.18× |
| fib | swift-Ounchecked | 1538.5 | 220.2 | 6.99× |
| fib | rust-align32 | 1471.5 | 208.8 | 7.05× |
| fib | swift-O-align32 | 1554.0 | 215.2 | 7.22× |
| sends | rust | 2382.6 | 424.1 | 5.62× |
| sends | rust-native | 2390.0 | 412.4 | 5.80× |
| sends | swift-O | 2524.1 | 470.4 | 5.37× |
| sends | swift-Ounchecked | 2564.6 | 441.5 | 5.81× |
| sends | rust-align32 | 2398.3 | 428.5 | 5.60× |
| sends | swift-O-align32 | 2558.3 | 470.2 | 5.44× |
| alloc | rust | 2042.1 | 472.9 | 4.32× |
| alloc | rust-native | 2035.2 | 486.3 | 4.19× |
| alloc | swift-O | 2090.8 | 535.8 | 3.90× |
| alloc | swift-Ounchecked | 2124.9 | 502.7 | 4.23× |
| alloc | rust-align32 | 2039.9 | 483.2 | 4.22× |
| alloc | swift-O-align32 | 2097.9 | 495.7 | 4.23× |
<!-- /generated -->

## 7. On the devices

<!-- generated: devices -->
<!-- /generated -->

## 8. Caveats

<!-- generated: caveats -->
- Runtimes missing from this run: none.
- Thermal state at the runs' starts: fair 284, nominal 57 runs.
- Refused runs: none; every run printed its kernel's checksum.
- Spread of the medians ((max − min) / median over each row's 5 rounds): at most 14.9% (CPython, arith); 7 of 65 rows above 5%: CPython arith 14.9%, CPython dispatch 12.9%, Java (ZGC) binarytrees 10.1%, LuaJIT dispatch 8.9%, LuaJIT fib 7.6%, C (clang -O2) arith 6.1%, Kajo (kasm), 8 workers (aggregate) dispatch 5.8%.
- Drift: the first kernel (fib) run again at the end took 0.978 to 1.010 times its median (LuaJIT to Ruby).
- Every time is the whole process's wall time, start-up included for every runtime alike (Kajo loads its image or assembles its kasm, the JVM and Pharo start their VMs); a run of a few hundred milliseconds is mostly start-up.
<!-- /generated -->

## 9. Reproducing

`just perf` runs the comparison (`experiments/runtime-comparison/bench.sh`,
about 40 minutes), then `just bench` into
`experiments/runtime-comparison/slices-raw.txt` (the language experiment's
own raw file stays as published), then regenerates this file and its graphs;
`just perf-report` regenerates them from the raw files alone. The runtimes are
Homebrew's (`brew install lua luajit openjdk ruby`, Node from the machine's
own install) and Pharo 12 from its zeroconf download into
`experiments/runtime-comparison/pharo/`. Versions of this run:

<!-- generated: versions -->
| runtime | version |
|---|---|
| Kajo (kasm) | e2dac1f release -enable-testing aligned, Swift 6.4.2 |
| Kajo (Smalltalk) | e2dac1f release -enable-testing aligned, Swift 6.4.2 |
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

Raw files: `experiments/runtime-comparison/bench-raw.txt` (5 rounds) and `experiments/runtime-comparison/slices-raw.txt`.
<!-- /generated -->
