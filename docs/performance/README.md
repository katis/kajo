# Kajo's performance

How fast Kajo's interpreter and collector are against runtimes a reader
knows, measured on one machine on one day. The prose is written by hand; every
number, table and graph between `generated` markers is written by
`scripts/perf-report.py` from the raw files and is never edited by hand.

<!-- generated: meta -->
Measured 2026-11-09 02:34 EET at commit `49984bb` on Apple M2 Pro, 8 P-cores + 4 E-cores, 32 GB, Mac14,12, macOS 27.2 (26B123); 5 interleaved rounds, every run bounded at 120 s; the time is the process's wall time.
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
Pharo went from 4.3 to 3.8 times; the rest of that gap was the library
(section 5), not the interpreter, and the collections-speed follow-up of
2026-11-08 took it to 2.8 (6.26 s to 4.45; the rows here are from the
re-run of 2026-11-09 on 49984bb, every other runtime within 2 percent of
its 2026-11-07 row). The same re-run has binarytrees at 8 workers 4
percent faster (1.80 and 1.85 s against 1.88 and 1.94) from the sweep
stop's removal below.

## 2. Sends

<!-- generated: sends -->
**fib** (960 × fib(27 or 28), 798,757,440 calls per run)

![fib: recursive Fibonacci](fib.svg)

| runtime | median s | min–max s | spread | time against Kajo (kasm) | M calls/s |
|---|--:|--:|--:|--:|--:|
| Java (G1) | 0.675 | 0.669–0.689 | 3.0% | 0.05× | 1183.3 |
| C (clang -O2) | 0.714 | 0.705–0.718 | 1.9% | 0.05× | 1119.0 |
| LuaJIT | 1.37 | 1.31–1.38 | 5.4% | 0.10× | 583.0 |
| Node (V8) | 1.82 | 1.81–1.83 | 0.8% | 0.13× | 439.9 |
| Pharo 12 (Cog JIT) | 2.29 | 2.28–2.29 | 0.6% | 0.16× | 349.4 |
| Ruby --yjit | 2.81 | 2.80–2.81 | 0.3% | 0.20× | 284.5 |
| LuaJIT -joff | 6.52 | 6.49–6.61 | 1.8% | 0.47× | 122.6 |
| Ruby | 12.8 | 12.7–12.9 | 1.5% | 0.91× | 62.6 |
| Lua 5.4 | 12.8 | 12.8–12.8 | 0.1% | 0.91× | 62.5 |
| **Kajo (kasm)** | 14.0 | 13.9–14.0 | 0.6% | 1.00× | 57.0 |
| **Kajo (Smalltalk)** | 14.8 | 14.7–14.8 | 0.8% | 1.06× | 54.0 |
| Java -Xint | 16.4 | 16.3–16.5 | 0.9% | 1.17× | 48.8 |
| CPython | 21.4 | 21.3–21.7 | 1.5% | 1.53× | 37.3 |
| Node --jitless | 21.7 | 21.5–21.8 | 1.6% | 1.55× | 36.7 |
| **Kajo (kasm), 8 workers (aggregate)** | 1.88 | 1.87–1.91 | 2.1% | 0.13× | 424.6 |
| **Kajo (Smalltalk), 8 workers (aggregate)** | 2.00 | 1.98–2.02 | 2.2% | 0.14× | 399.0 |

**dispatch** (100,000,000 sends over three classes plus an indexed read per run)

![dispatch: one polymorphic send site](dispatch.svg)

| runtime | median s | min–max s | spread | time against Kajo (kasm) | M sends/s |
|---|--:|--:|--:|--:|--:|
| LuaJIT | 0.102 | 0.101–0.105 | 3.8% | 0.02× | 984.3 |
| Node (V8) | 0.245 | 0.242–0.248 | 2.2% | 0.06× | 408.0 |
| C (clang -O2) | 0.252 | 0.249–0.255 | 2.5% | 0.06× | 397.6 |
| Java (G1) | 0.377 | 0.371–0.382 | 2.9% | 0.09× | 265.4 |
| Pharo 12 (Cog JIT) | 0.730 | 0.723–0.735 | 1.6% | 0.17× | 137.0 |
| Java -Xint | 2.69 | 2.68–2.72 | 1.3% | 0.64× | 37.2 |
| LuaJIT -joff | 2.81 | 2.75–2.84 | 3.2% | 0.67× | 35.5 |
| **Kajo (Smalltalk)** | 3.54 | 3.54–3.59 | 1.7% | 0.85× | 28.2 |
| Ruby --yjit | 3.77 | 3.75–3.81 | 1.5% | 0.90× | 26.6 |
| **Kajo (kasm)** | 4.18 | 4.18–4.18 | 0.2% | 1.00× | 23.9 |
| Lua 5.4 | 4.22 | 4.09–4.27 | 4.3% | 1.01× | 23.7 |
| Node --jitless | 4.40 | 4.32–4.46 | 3.1% | 1.05× | 22.7 |
| Ruby | 4.64 | 4.61–4.65 | 1.0% | 1.11× | 21.5 |
| CPython | 17.5 | 17.1–18.7 | 9.2% | 4.20× | 5.7 |
| **Kajo (Smalltalk), 8 workers (aggregate)** | 0.526 | 0.509–0.541 | 6.2% | 0.13× | 190.1 |
| **Kajo (kasm), 8 workers (aggregate)** | 0.587 | 0.584–0.597 | 2.2% | 0.14× | 170.4 |
<!-- /generated -->

## 3. Allocation and collection

<!-- generated: allocation -->
**binarytrees** (one long-lived tree of depth 12, then 1280 trees of depth 16 built, checked and dropped: 167,779,071 objects per run)

![binarytrees](binarytrees.svg)

| runtime | median s | min–max s | spread | time against Kajo (kasm) | M objects/s |
|---|--:|--:|--:|--:|--:|
| Java (G1) | 0.586 | 0.576–0.596 | 3.3% | 0.05× | 286.5 |
| Java (ZGC) | 0.928 | 0.892–0.985 | 10.0% | 0.08× | 180.8 |
| Pharo 12 (Cog JIT) | 1.88 | 1.87–1.89 | 1.1% | 0.16× | 89.2 |
| C (clang -O2) | 2.46 | 2.45–2.47 | 0.6% | 0.21× | 68.3 |
| Node (V8) | 2.78 | 2.76–2.79 | 1.0% | 0.24× | 60.3 |
| LuaJIT | 6.23 | 6.19–6.25 | 1.0% | 0.54× | 26.9 |
| Java -Xint | 9.30 | 9.25–9.35 | 1.1% | 0.81× | 18.0 |
| LuaJIT -joff | 9.58 | 9.55–9.60 | 0.6% | 0.84× | 17.5 |
| Ruby --yjit | 10.9 | 10.8–10.9 | 1.4% | 0.95× | 15.4 |
| **Kajo (kasm)** | 11.5 | 11.4–11.5 | 0.2% | 1.00× | 14.6 |
| **Kajo (Smalltalk)** | 11.8 | 11.7–11.8 | 0.7% | 1.03× | 14.3 |
| Node --jitless | 13.9 | 13.9–14.0 | 0.5% | 1.21× | 12.1 |
| Ruby | 18.7 | 18.1–19.3 | 6.3% | 1.63× | 9.0 |
| Lua 5.4 | 21.2 | 21.1–21.3 | 1.2% | 1.85× | 7.9 |
| CPython | 37.8 | 37.7–37.8 | 0.4% | 3.30× | 4.4 |
| **Kajo (kasm), 8 workers (aggregate)** | 1.80 | 1.78–1.83 | 2.7% | 0.16× | 93.3 |
| **Kajo (Smalltalk), 8 workers (aggregate)** | 1.85 | 1.84–1.87 | 1.4% | 0.16× | 90.6 |

Collector pauses where the runtime reports them (medians over the rounds of each run's own percentiles; Kajo's pauses are its stops, its young collections on one worker run on the program's own thread; the JVM's from `-Xlog:gc`; Pharo reports only counts and totals):

| runtime | collections per run | pause p50 ms | pause p99 ms | pause max ms | Kajo's own young collections p50 / p99 ms |
|---|--:|--:|--:|--:|--:|
| Java (G1) | 12 pauses | 0.717 | 1.048 | 1.048 | - |
| Java (ZGC) | 15 pauses | 0.005 | 0.008 | 0.008 | - |
| Pharo 12 (Cog JIT) | 260 scavenges, 0 full (0 ms) | 0.685 (mean) | - | - | - |
| Java -Xint | 14 pauses | 0.633 | 1.100 | 1.100 | - |
| Kajo (kasm) | 1280 young, 36 stops | 0.089 | 0.267 | 0.267 | 1.634 / 1.878 |
| Kajo (Smalltalk) | 1280 young, 36 stops | 0.092 | 0.304 | 0.304 | 1.634 / 1.873 |
| Kajo (kasm), 8 workers (aggregate) | 1280 young, 42 stops | 0.206 | 0.394 | 0.394 | 2.111 / 4.455 |
| Kajo (Smalltalk), 8 workers (aggregate) | 1280 young, 39 stops | 0.220 | 0.381 | 0.381 | 2.132 / 4.369 |
<!-- /generated -->

Until 2026-11-08 the 8-worker rows had 19 to 30 ms stops, seven a run of the
kind the large-bytes follow-up added: an allocation that found the entry
table empty finished the whole lazy sweep in a stop of its own
(`sweepsForEntries`, 42 ms of sweeping in stops over a 1.8 s run) instead of
falling back to a full collection, filed under `other` in `stopsByKind`. The
sweep-stop follow-up (`docs/modules/sweep-stop.md`) gave the stop its own
kind `sweep`, bounded it to a partial apply (the pending runs handed to the
allocators, at most 4096 words swept inside the stop) and started cycles
from the entry table's own rate, so the rows above, from the re-run of
2026-11-09, have a longest stop of 0.34 to 0.49 ms over the ten 8-worker
runs (the module's own interleaved runs: 0 to 1 sweep stops a run at 0.10
to 0.17 ms, every stop kind under 0.6 ms).

## 4. Bytecodes

<!-- generated: bytecodes -->
**arith** (320,000,000 iterations of `sum := sum + (i * 3 + 7)`, a conditional subtract of 1000000007; in Kajo's kasm 7,334,400,000 bytecodes per run)

![arith](arith.svg)

| runtime | median s | min–max s | spread | time against Kajo (kasm) | M iterations/s |
|---|--:|--:|--:|--:|--:|
| Java (G1) | 0.287 | 0.286–0.291 | 1.7% | 0.04× | 1115.0 |
| LuaJIT | 0.403 | 0.400–0.406 | 1.6% | 0.05× | 793.8 |
| C (clang -O2) | 0.415 | 0.413–0.423 | 2.5% | 0.05× | 770.7 |
| Node (V8) | 0.422 | 0.417–0.424 | 1.5% | 0.05× | 758.3 |
| Pharo 12 (Cog JIT) | 1.47 | 1.47–1.48 | 0.8% | 0.18× | 217.8 |
| LuaJIT -joff | 4.71 | 4.70–4.72 | 0.5% | 0.59× | 68.0 |
| Lua 5.4 | 5.60 | 5.58–5.60 | 0.3% | 0.70× | 57.2 |
| Node --jitless | 5.98 | 5.96–5.99 | 0.5% | 0.75× | 53.5 |
| Java -Xint | 6.75 | 6.69–6.76 | 1.0% | 0.84× | 47.4 |
| Ruby --yjit | 7.77 | 7.76–7.79 | 0.4% | 0.97× | 41.2 |
| Ruby | 7.78 | 7.76–7.80 | 0.5% | 0.97× | 41.1 |
| **Kajo (kasm)** | 8.00 | 7.99–8.00 | 0.1% | 1.00× | 40.0 |
| **Kajo (Smalltalk)** | 8.04 | 8.02–8.05 | 0.3% | 1.01× | 39.8 |
| CPython | 44.8 | 43.7–49.0 | 11.7% | 5.60× | 7.1 |

Kajo (kasm) runs 919 M bytecodes/s in its own kernel time (7.98 s of the 8.00 s process).
<!-- /generated -->

## 5. The Smalltalk library against Pharo

<!-- generated: library -->
**collections** (three times: an OrderedCollection of a million SmallIntegers filled and summed with `do:` and `inject:into:`; a Dictionary of 200 000 Symbol keys built and looked up; a String of a million characters built with a WriteStream and scanned; 500 000 SmallIntegers sorted; the same source in both)

![collections](collections.svg)

| runtime | median s | min–max s | spread | time against Kajo (Smalltalk) |
|---|--:|--:|--:|--:|
| Pharo 12 (Cog JIT) | 1.61 | 1.60–1.61 | 1.0% | 0.36× |
| **Kajo (Smalltalk)** | 4.45 | 4.43–4.48 | 1.0% | 1.00× |
<!-- /generated -->

The program's four parts, each alone in the same harness (the
collections-speed module, 2026-11-08, `docs/modules/collections-speed.md`;
`KERNELS="$PARTS" RUNTIMES="kajo-st pharo" bench.sh`, five interleaved
rounds, thermal nominal throughout). Hand-written, not generated: the raw
rows are the module's, not `bench-raw.txt`'s. *Net* is the median less the
runtime's empty program (start and exit alone: Kajo 44 ms, Pharo 59 ms),
which is most of Pharo's stream part. Sends are `kajo run`'s full sends (the
method cache's, special sends that fell back included) and bytecodes the
plain instructions the counting build dispatched, per element (a million
integers added and summed, 200 000 keys made, put and looked up, a million
Characters written and scanned, 500 000 integers sorted; each three times).
The JIT is 5.5 to 6 times Kajo's interpreter on fib, dispatch and arith; a
part far past that is the library's.

| part | before: Kajo s | Pharo s | net ratio | sends / element | cycles / bytecode | after: Kajo s | Pharo s | net ratio | sends / element | cycles / bytecode |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| OrderedCollection | 0.493 | 0.297 | 1.89 | 2.0 | 6.33 | 0.491 | 0.297 | 1.88 | 2.0 | 6.35 |
| Dictionary of Symbols | 3.174 | 1.158 | 2.85 | 152.6 | 11.59 | 1.691 | 1.166 | 1.49 | 56.8 | 11.63 |
| WriteStream and scan | 0.860 | 0.112 | **15.5** | 8.0 | 7.75 | 0.525 | 0.111 | 9.2 | 5.0 | 8.05 |
| sort | 1.885 | 0.457 | 4.63 | 3.0 | 5.22 | 1.882 | 0.458 | 4.61 | 3.0 | 5.22 |
| **whole program** | 6.258 | 1.613 | 4.00 (3.88 whole) | | | 4.452 | 1.609 | 2.84 (2.77 whole) | | |

Only the stream part was the library's: a `nextPut:` sent four times and a
`contents` copied byte by byte. The Dictionary part's time was mostly its
keys' `printString` (57 percent, 105 sends a number), the stream again. The
sort (18 block activations and 789 bytecodes an element) and the
OrderedCollection are the interpreter's. The table above the parts is the
comparison's own run on the commit before the module and is not re-run.

## 6. Scaling across workers

<!-- generated: scaling -->
![scaling](scaling.svg)

| runtime | kernel | 1 worker s | 8 workers s | speedup |
|---|---|--:|--:|--:|
| Kajo (kasm) | fib | 14.0 | 1.88 | 7.45× |
| Kajo (Smalltalk) | fib | 14.8 | 2.00 | 7.39× |
| Kajo (kasm) | dispatch | 4.18 | 0.587 | 7.12× |
| Kajo (Smalltalk) | dispatch | 3.54 | 0.526 | 6.74× |
| Kajo (kasm) | binarytrees | 11.5 | 1.80 | 6.37× |
| Kajo (Smalltalk) | binarytrees | 11.8 | 1.85 | 6.35× |
<!-- /generated -->

The language experiment's Rust and Swift slices (`just bench`,
`experiments/vm-language-bench`), the evidence ADR 0001 rests on: the same
kasm kernels at their original sizes on a minimal VM, not Kajo's core.

<!-- generated: slices -->
From machine: Apple M2 Pro, 8 P-cores + 4 E-cores, no pinning.

| kernel | variant | 1 worker ms | 8 workers ms | speedup |
|---|---|--:|--:|--:|
| arith | rust | 2996.6 | 406.7 | 7.37× |
| arith | rust-native | 2985.4 | 411.2 | 7.26× |
| arith | swift-O | 3046.5 | 420.1 | 7.25× |
| arith | swift-Ounchecked | 3050.8 | 416.8 | 7.32× |
| arith | rust-align32 | 3000.2 | 414.7 | 7.23× |
| arith | swift-O-align32 | 3051.7 | 416.9 | 7.32× |
| fib | rust | 1458.7 | 204.2 | 7.14× |
| fib | rust-native | 1462.6 | 202.4 | 7.23× |
| fib | swift-O | 1534.5 | 213.5 | 7.19× |
| fib | swift-Ounchecked | 1536.1 | 214.6 | 7.16× |
| fib | rust-align32 | 1470.3 | 200.4 | 7.34× |
| fib | swift-O-align32 | 1543.5 | 215.2 | 7.17× |
| sends | rust | 2391.9 | 422.6 | 5.66× |
| sends | rust-native | 2380.3 | 421.7 | 5.64× |
| sends | swift-O | 2518.0 | 461.5 | 5.46× |
| sends | swift-Ounchecked | 2565.7 | 462.3 | 5.55× |
| sends | rust-align32 | 2392.5 | 437.7 | 5.47× |
| sends | swift-O-align32 | 2557.3 | 435.7 | 5.87× |
| alloc | rust | 2040.8 | 478.0 | 4.27× |
| alloc | rust-native | 2024.6 | 474.2 | 4.27× |
| alloc | swift-O | 2089.3 | 526.2 | 3.97× |
| alloc | swift-Ounchecked | 2112.6 | 497.6 | 4.25× |
| alloc | rust-align32 | 2034.0 | 487.0 | 4.18× |
| alloc | swift-O-align32 | 2092.0 | 510.2 | 4.10× |
<!-- /generated -->

## 7. On the devices

<!-- generated: devices -->
<!-- /generated -->

## 8. Caveats

<!-- generated: caveats -->
- Runtimes missing from this run: none.
- Thermal state at the runs' starts: nominal 341 runs.
- Refused runs: none; every run printed its kernel's checksum.
- Spread of the medians ((max − min) / median over each row's 5 rounds): at most 11.7% (CPython, arith); 6 of 65 rows above 5%: CPython arith 11.7%, Java (ZGC) binarytrees 10.0%, CPython dispatch 9.2%, Ruby binarytrees 6.3%, Kajo (Smalltalk), 8 workers (aggregate) dispatch 6.2%, LuaJIT fib 5.4%.
- Drift: the first kernel (fib) run again at the end took 0.972 to 1.004 times its median (Java (G1) to LuaJIT).
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
| Kajo (kasm) | 49984bb release -enable-testing aligned, Swift 6.4.2 |
| Kajo (Smalltalk) | 49984bb release -enable-testing aligned, Swift 6.4.2 |
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
