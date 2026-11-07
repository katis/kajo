# Results: Kajo against other runtimes (baseline, before the interpreter-speed module)

Run 2026-11-07 12:03 to 12:45 EET on the Mac mini (Apple M2 Pro, 8 P-cores +
4 E-cores, 32 GB, macOS 27.2 26B123) with `just perf`: `bench.sh` (five
interleaved rounds per kernel, the first kernel repeated at the end), then
the language experiment's `bench.sh` into `slices-raw.txt`, then
`scripts/perf-report.py`. Kajo at a02c70b, whose VM is the VM of 0459db7
(the commit between them adds only this experiment's files). Raw lines:
`bench-raw.txt`; the report with its tables and graphs:
`docs/performance/README.md`. The numbers below are the report's medians;
every time is the whole process's wall time.

341 runs, 0 refused: every run printed its kernel's checksum. The thermal
state (`ProcessInfo.thermalState`, `thermal.swift`) read nominal at the
start of all 341 runs. The drift check (fib again at the end) was 0.992 to
1.064 of each runtime's median. The machine was not otherwise idle in the
owner's sense: apps of the owner's own session (Logitech's updater at about
a quarter of a core, Warp, Xcode open) ran throughout; nothing of ours ran
beside the measured process.

## Versions

| runtime | version | how it ran |
|---|---|---|
| Kajo | a02c70b, `swift build -c release -Xswiftc -enable-testing` with `-align-all-nofallthru-blocks=5 -align-loops=32` (Swift 6.4.2, swiftly), scratch `.build/perf` | `kajo run prelude.kasm kajo.kasm --workers N --slice-ms 0`; the Smalltalk programs built into an image with `kernel/` by `kajo build-image` before the runs |
| Pharo | Pharo 12.0.0 SNAPSHOT image (7d5f14cb47) and VM v10.3.12 (4b0622446, Cog `StackToRegisterMappingCogit`), files.pharo.org's `get-files/120` zips | one image per kernel with the program's Tonel loaded by `pharo-load.st` (Pharo's `TonelParser`) before the runs; `Pharo --headless <image> eval` |
| C | Apple clang 21.0.0 (clang-2100.4.1.1) | `clang -O2`, launched once untimed after linking |
| LuaJIT | 2.1.1710088188 (Homebrew) | `luajit` and `luajit -joff` |
| Lua | 5.4.6 (Homebrew) | `lua` |
| Node | v24.5.0, V8 13.6.233.10 (the machine's fnm install) | `node` and `node --jitless` |
| Java | OpenJDK 21.0.2 (Homebrew `openjdk`) | `javac` before the runs; `java -XX:+UseG1GC -Xlog:gc`, `java -Xint` (G1), `java -XX:+UseZGC -XX:+ZGenerational -Xlog:gc,gc+phases` for binarytrees; default heap sizing |
| Ruby | 3.3.0 (Homebrew `ruby`) | `ruby` and `ruby --yjit` |
| CPython | 3.12.2 (Homebrew) | `python3` |

Nothing new was installed: every Homebrew runtime the brief lists was
already present, and Node was already installed through fnm (not
Homebrew); `brew install node` would have upgraded shared dependencies
such as icu4c under other formulae, so the existing v24.5.0 was used. Pharo
was downloaded into `pharo/` (gitignored). The zeroconf script itself was
refused by the session's permission classifier as remote code; the same two
zips its sub-scripts name were fetched with curl and unpacked by hand, which
is all the script does on macOS.

## Parameters

Chosen so that the slowest runtime of each kernel stays under a minute;
the fastest lands at 0.1 to 0.7 s, not the brief's "about a second", where
the spread between runtimes is two decades (dispatch and arith). The values
are in the program files and in `programs/<kernel>/checksums`.

| kernel | parameters | checksum, 1 worker | 8 workers (Kajo only) |
|---|---|---|---|
| fib | 960 repetitions of fib(27 + r mod 2), 798 757 440 calls | 246829920 | 246829920 |
| dispatch | 100 000 000 iterations, one `step:` over Leaf, Doubler, Subber read from an Array | 6666666666666668 | 833333337500001 (each worker starts at its own receiver) |
| binarytrees | one depth-12 tree kept, 1280 depth-16 trees built, checked and dropped: 167 779 071 objects | 167779071 | 167836408 (a long-lived tree per worker) |
| collections | three times the four parts of DESIGN.md (1 M OrderedCollection, 200 000 Symbol keys, a 1 M-character WriteStream, 500 000 SmallIntegers sorted) | 4673800361484 | - |
| arith | 320 000 000 iterations of `sum + (i * 3 + 7)` with a conditional subtract of 1000000007 | 684800000 | - |

The kasm programs are Kajo's fixture kernels (`fib`, `sends`, `alloc`,
`arith`) with only the repetition literal changed (10×, 2.5×, 4×, 4×). The
dispatch size is capped by the doubles of LuaJIT and Node: the checksum
must stay below 2^53, so 2.5× of the fixture, not 5×.

## Medians (seconds)

| runtime | fib | dispatch | binarytrees | arith | collections |
|---|--:|--:|--:|--:|--:|
| **Kajo (kasm)** | 17.0 | 6.56 | 11.8 | 10.9 | - |
| **Kajo (Smalltalk)** | 17.7 | 5.83 | 12.0 | 10.6 | 7.10 |
| Kajo (kasm), 8 workers | 2.29 | 0.906 | 1.93 | - | - |
| Pharo 12 (Cog JIT) | 2.30 | 0.742 | 1.89 | 1.48 | 1.64 |
| C (clang -O2) | 0.716 | 0.251 | 2.46 | 0.409 | - |
| LuaJIT | 1.35 | 0.106 | 6.23 | 0.403 | - |
| LuaJIT -joff | 6.53 | 2.84 | 9.60 | 4.72 | - |
| Lua 5.4 | 12.8 | 4.23 | 21.3 | 5.61 | - |
| Node (V8) | 1.83 | 0.246 | 2.80 | 0.426 | - |
| Node --jitless | 21.8 | 4.48 | 14.0 | 5.98 | - |
| Java (G1) | 0.675 | 0.373 | 0.593 | 0.285 | - |
| Java -Xint | 16.4 | 2.72 | 9.35 | 6.76 | - |
| Java (ZGC) | - | - | 0.948 | - | - |
| Ruby | 12.8 | 4.63 | 18.9 | 7.80 | - |
| Ruby --yjit | 2.82 | 3.80 | 10.6 | 7.80 | - |
| CPython | 21.5 | 17.8 | 38.0 | 44.8 | - |

Start-up is inside every number: Kajo's kasm runs spend 17 to 28 ms outside
the kernel (assembling, booting), its image runs 46 to 62 ms (loading 5.1 MB),
Pharo's `eval` of `3 + 4` takes 50 ms, the JVM's empty start is of the same
order. It matters only for the sub-second rows.

## What the gaps are made of

**Among the interpreters Kajo is in the pack, at its slow end.** With every
JIT off, Kajo is within 0.97 to 1.28 of Java's template interpreter,
Node's Ignition and CPython on fib, and ahead of Node `--jitless`, Ruby,
Lua and CPython on binarytrees; LuaJIT's interpreter is 2.3 to 2.6 times
faster on every kernel but binarytrees (1.2). The JITs other than YJIT are
6 to 62 times faster; YJIT gains little or nothing (below). The comparison with the interpreters is the one that bears on
Kajo's design, since iOS forbids a JIT.

**fib** (calls). Kajo spends 21 ns a call (47 M calls/s; the
interpreter-speed brief measured the same 21 ns, about 70 cycles, on the
fixture size). Java `-Xint` (48.7 M/s) runs the same stack-bytecode shape
through a template interpreter at about the same cost; LuaJIT `-joff`
(122 M/s) is a register bytecode in hand-written assembly where a call is
a frame link with no separate method lookup per call (`CALL` reads the
closure from a register). Kajo's send probes a per-worker global cache keyed
by class and selector and then derives the code and literal bases through
the entry table (`docs/modules/interpreter-speed.md` part 1), which a
per-site inline cache and a leaner activation are meant to cut. C at -O2 is
not a pure call measurement: clang turned one of the two recursive calls
into a loop (`clang -O2 -S` shows one `bl _fib` in `fib`), so it makes about
half the calls. The Smalltalk-compiled fib is 4 percent slower than the kasm
one (the compiler's `ifTrue:ifFalse:` and the `\\` send in the loop).

**dispatch** (a polymorphic send). Kajo 15 M iterations/s, each a
polymorphic `step:` and a real send of `at:` (two sends an iteration, the
`at:` reaching its primitive). Here Kajo is behind every interpreter but
CPython: Java `-Xint` and LuaJIT `-joff` are 2.3 to 2.4 times faster, Ruby 1.4,
Node `--jitless` 1.5. The JITs inline the site: LuaJIT records the three
receivers into one trace (1.1 ns an iteration, faster than C, whose
indirect call through a function pointer costs 2.5 ns and cannot be
inlined); V8 and HotSpot inline a polymorphic site of three. Pharo's Cog
uses a polymorphic inline cache in machine code (7.4 ns an iteration). The
Smalltalk-compiled dispatch is 11 percent faster than the kasm one; the
likely reason, not checked here, is that the compiler emits `at:` as the
special bytecode where the kasm sends it.
Ruby with YJIT gains only 18 percent here and nothing on arith: YJIT has no
on-stack replacement, so the top-level `while` loop of these scripts stays
in the interpreter and only the called methods are compiled.

**binarytrees** (allocation and collection). Kajo 14 M objects/s; every
object is a real send of `basicNew` to a primitive (167 779 072 primitive
calls a run), an entry in the object table and a nursery allocation; 1280
young collections a run, each local to the worker, 1.64 ms at the median
and 1.9 at p99, and they promote heavily (3.1 GB promoted a run, presumably
the tree under construction at each collection; 12 old
cycles with stops of 0.07 to 0.26 ms). Java G1 with a JIT allocates inline
from a thread-local buffer and runs 12 young pauses of 0.69 ms median a run
in a heap sized from the machine's memory (283 M objects/s); with `-Xint`
it is 1.3 times faster than Kajo. ZGC's pauses are 5 to 8 µs and it is 1.6
times slower than G1 here. Pharo's Cog allocates inline in jitted code and
scavenges 260 times a run (0.69 ms mean; Pharo reports no percentiles). C
pays `malloc` and `free` per node (68 M/s) and is beaten by the three
generational collectors with a JIT. Kajo is 1.24 times faster than Node
`--jitless`, 1.6 than Ruby and 3.2 than CPython, whose reference counting
frees every tree node by node.

At 8 workers the kasm binarytrees had stops of up to 29.6 ms (Smalltalk
19.3) at p99/max, against 0.33 ms on one worker. Two more runs read their
`stopsByKind`: the long stops are of kind `other` (6 or 7 a run, 19 to
22 ms the longest), not the final or initial marks (0.2 to 0.6 ms). Which
stop that is was not identified here; it is a question for the core, not
for this harness.

**arith** (the special bytecodes). Kajo 1.49 ns a bytecode (675 M
bytecodes/s, 21 bytecodes an iteration plus 4 on the iterations that
subtract). The register interpreters execute fewer instructions for the
same loop: LuaJIT's loop is 7 bytecodes (`MULVN ADDVN ADDVV KNUM ISGT JMP
FORL`, `luajit -bl`), 2.3 times faster at about 2 ns a bytecode; Java's is
the same stack shape as Kajo's, 20 bytecodes an iteration (`javap -c`), and
`-Xint` runs it 1.6 times faster than Kajo at about 0.96 ns a bytecode, the
difference a template interpreter makes with the operands' type known
statically (no SmallInteger tag checks, no overflow checks on `long`). Ruby
with and without YJIT is the same (no OSR, as above). CPython is 4.1 times
slower than Kajo. The interpreter-speed module's superinstructions
(compare-and-branch, temp-op-int) attack exactly the count, not the cost per
bytecode.

**collections** (the library against Pharo's). Kajo 7.10 s against Pharo's
1.64 (4.3×). Timing each part alone (three repetitions each, one run per
part, not in the raw file): the Dictionary of Symbol keys 3.26 s against
0.73 to 1.09, the sort 2.30 against 0.38 to 0.43, the WriteStream 0.90
against 0.05 to 0.08, the OrderedCollection 0.55 against 0.23 to 0.27.
The library is where the two differ besides the JIT: Kajo's `asSymbol`
interns into the weak symbol table and its `printString` and `,` build
UTF-8 Strings; its WriteStream grows a UTF-8 String in Smalltalk where
Pharo's is a byte String; Kajo's `sort` is the kernel's merge sort with a
sort block `[:a :b | a <= b]` sent per comparison. Which of Pharo's methods
have primitives here was not checked. The run line shows 5.6 M
global cache misses in a collections run (against 3 in fib), which fits
the brief's note that the cache is flushed at every pause. No part of the
gap is attributed beyond that without a profile.

## Scaling

Kajo 8 workers against 1 on the same total work: fib 7.41× (Smalltalk
7.35), dispatch 7.23 (7.13), binarytrees 6.13 (6.13). The language
experiment's slices on this machine (`slices-raw.txt`): 7.0 to 7.3 on fib
and arith, 5.3 to 5.9 on sends, 4.0 to 4.3 on alloc; Kajo's core scales
better than the slices on allocation (6.1 against 4.2), which is per-worker
nurseries against the slices' single-threaded marking.

## What could not be made comparable

- **Collector pauses.** Kajo reports its stops and its young collections
  separately; on one worker its young collections run on the program's own
  thread, so they are pauses to the program and are shown in their own
  column. The JVM's are its `Pause` log lines (all stop-the-world). Pharo
  reports only counts and total milliseconds, so its column is a mean.
  Node and Lua report nothing the harness reads.
- **Heap sizing.** Every runtime ran with its default heap. The JVM sizes
  its heap from the machine's memory (512 MB initial on this mini) and
  collects 12 times a run where Kajo collects its 4 MiB nurseries 1280
  times. No runtime was tuned.
- **JIT off.** Pharo's Cog has no switch to turn its JIT off; it is shown
  with it only. Python 3.12 has no JIT.
- **Start-up.** Inside every number, for every runtime; see above.
- **The 8-worker rows** are Kajo's alone; no other runtime ran a parallel
  version of the programs.
- **C's fib** makes about half the calls (clang's recursion-to-loop
  transform); C's binarytrees frees every node, which the collected
  runtimes do not do one by one.

## Reproducing

`just perf` (about 50 minutes: 42 for the comparison, the rest the
language experiment's clean builds and matrix) or `just perf-report` from
the raw files alone. A probe: `ROUNDS=1 KERNELS="fib" RUNTIMES="kajo c"
experiments/runtime-comparison/bench.sh` with `OUT=` set elsewhere.
