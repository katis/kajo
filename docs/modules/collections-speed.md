# Collections speed

A kernel follow-up to the runtime comparison (`docs/performance/README.md`
section 5). Briefed 2026-11-08 from the owner's choice of 2026-11-08
("point 2": the library, measured first; no dictionary-probe primitive, no
profiler yet).

## Where it stands

The comparison's `collections` program (an OrderedCollection of a million
SmallIntegers filled and summed with `do:` and `inject:into:`; a Dictionary
of 200 000 Symbol keys built and looked up; a String of a million
characters built with a WriteStream and scanned; 500 000 SmallIntegers
sorted; three times) takes 6.25 s in Kajo against Pharo 12's 1.63 s with
its Cog JIT: 3.8 times. On fib, dispatch and arith the same JIT is 5.5 to
6 times faster than Kajo's interpreter, so most of the collections gap is
the interpreter against a JIT, not the library, and the primitive-heavy
parts narrow it. What is left to the library is whatever a part costs
beyond that ratio.

The kernel already has the obvious things: `String hash` and `Symbol hash`
are primitive 122, `String =` is primitive 121 (`sameBytesAs:`), `do:` on
`SequenceableCollection` and `OrderedCollection` are `to:do:` loops over
the backing array, growth is by doubling, `HashedCollection>>indexFor:` is
one compact probe loop with hook sends (`hashFor:`, `equal:to:`,
`keyOf:`). Still Smalltalk loops: `ByteArray hash` (a block per byte),
`ByteArray =` (inherited element-wise from `SequenceableCollection`), both
on the large-bytes follow-up's not-done list; `WriteStream nextPut:` sends
about six times per character (`isText`, `isCharacter`, `encode:at:`,
`isNil`, `+`, `max:`); `Symbol asString` is `'' , self`.

## Parts

1. **Measure per part first.** Split the program into its four parts and
   time each alone in Kajo and Pharo in the same session (the comparison's
   harness under `experiments/runtime-comparison/`; the Pharo image and
   loader are there), five rounds interleaved, at thermal nominal. For each
   part in Kajo read the sends and bytecodes per element with the counting
   build (`-DKAJO_COUNT_OPCODES`, `KAJO_OPCODE_COUNTS`) and `kajo run`'s
   cycles per bytecode. Tabulate: part, Kajo s, Pharo s, ratio, sends per
   element, cycles per bytecode. A part near the interpreter's ratio (5.5 to
   6) is the interpreter's; a part well past it is the library's. This
   table is the module's main output whatever parts 2 to 4 gain.

2. **ByteArray's hash and equality as primitives.** Primitives 121 and 122
   take any byte object, not only text (`isText` becomes the byte-object
   test; `sameBytesLong` and `byteHashLong` likewise, so a long ByteArray is
   polled as a long String is); `ByteArray>>hash` and `ByteArray>>=` use
   them with the Smalltalk loops as the fallback and the class check kept
   (`#[1 2] = 'ab'` stays false; a String never equals a ByteArray; the hash
   of a ByteArray and of a String of the same bytes may be equal, say so in
   the method). Tests: equal and unequal arrays, different lengths, empty,
   past `ByteWork.chunk` (polled; a stop waits at most what the long
   String tests allow), the extreme-argument seeded test unchanged (no
   integer arguments), the kernel's `ByteArrayTest`. Every reader of a byte
   count is already in one table (large bytes); the changed primitives read
   through it.

3. **The WriteStream path.** Count the sends per `nextPut:` before, then
   tighten it without changing what the stream answers: the text test
   decided once per stream (a flag or a class per kind, the module's
   choice), `readLimit` maintained where it is read rather than on every
   put if `contents`, `position:` and `reset` keep their meaning, `max:`
   inlined by the compiler or avoided, the grow check as one comparison.
   `nextPutAll:` over a String or ByteArray copies with the existing copy
   primitive (38) in one step. The kernel's `WriteStreamTest` and the
   Tonel writer's byte-identical round trip (`kernel/` written back
   unchanged, `canonical-tonel.sh`) are the oracle: what the image writes
   must not change by a byte.

4. **What part 1 points at, within bounds.** For any part past the
   interpreter's ratio: kernel changes only (an algorithm, a growth policy,
   a send removed from a per-element loop, a hook inlined where the class is
   known), each with its before-and-after row. No new primitive beyond part
   2 is built here: if a part would need one (the sort of SmallIntegers,
   the probe loop), list it as an open question with the part's ratio and
   the sends per element it would remove, and whether an app rather than
   the benchmark would hit it (String keys compared with `=` are the app
   case; Symbol identity probes the benchmark's).

5. **Measure after.** Part 1's table again on the final commit beside the
   before table, the whole program's time against Pharo (before 3.8),
   the app-shaped proxy: the tools' scripted session against the
   2000-class image (`mode=devsession`, `KAJO_SHELL_CLASSES=2000`, Mac to
   Mac; `class.hierarchy` 335 ms and `package.selectors` 457 ms in module
   10's row) before and after, five sessions each; `just bench` A/B
   through `scripts/ab.sh` against the starting commit (within noise is the
   bar: the interpreter is not touched) and `interpret` identical by
   disassembly.

## Bar

- The per-part table (part, Kajo, Pharo, ratio, sends per element, cycles
  per bytecode) before and after, in the doc and in
  `docs/performance/README.md` section 5 beside the whole-program row (the
  report's generated blocks come from `scripts/perf-report.py`; add the
  per-part table as a hand-written block or extend the script with a
  fixture test, the module's choice, and re-run `just perf-report`).
- `ByteArray hash` and `ByteArray =` are primitives with the tests above;
  no part of the program is slower after than before.
- The image written back is byte-identical (`kernel/` unchanged by a round
  trip through the changed WriteStream).
- The scripted session's `class.hierarchy` and `package.selectors` are no
  slower, with their before and after medians stated.
- The A/B within noise (0.98 to 1.02 with overlapping ranges) and
  `interpret` identical but for page offsets; `just arc-check` passes.
- The core tier passes on the final code commit (`just check` picks it
  from the diff under `ObjectModel/`): all 18 gates, the A/B, the Mac and
  iPhone matrices, with its `gates.log` quoted; 205+ kernel tests and the
  compiler tests pass; the snapshot and syntax fuzzers run (the tier's
  rule for the diff).

## Open questions for the owner (build the recommended option, list the question)

1. Should `Symbol asString` and `String asSymbol` go through the concat
   and intern primitives directly rather than `'' , self`? Recommended:
   yes if part 1 shows them in a hot loop, otherwise leave it.
2. A sort primitive for Arrays of SmallIntegers with the default order,
   if part 1 shows the sort well past the interpreter's ratio.
   Recommended: not built; listed with its numbers.
3. The dictionary probe as a primitive for identity-comparable keys.
   Recommended: not built (the owner's 2026-11-08 decision); the part's
   ratio and sends per lookup are stated so the question has numbers.

## As built (2026-11-08)

Five commits on 1a6a1b8: fc64446 (part 1's harness), 1189577 (part 2,
the only VM change), ea9e2fe (part 3), ea9b7dc and 0c8e48a (part 4).
The final code commit is 0c8e48a. Nothing under `Sources/KajoVM/` changed
but `ObjectModel/Strings.swift` (primitives 121 and 122); nothing under
`Interpreter/`.

### Part 1: the parts measured

`experiments/runtime-comparison/programs/collections-{oc,dict,stream,sort}`
are the program's four parts, each run three times as in the program, and
`collections-empty` answers 0 (start and exit alone). `bench.sh` lists them
as `$PARTS`, run by `KERNELS="$PARTS collections" RUNTIMES="kajo-st pharo"
bench.sh`; the default `KERNELS` is unchanged, so `just perf` is. Each part's
checksum agrees between Kajo and Pharo and the four add up to the program's
(4673800361484). Five interleaved rounds, thermal nominal in every run
(`parts-raw-before.txt` and `parts-raw-after.txt` beside `bench.sh`).

Per element (a million integers added and summed, 200 000 keys made, put
and looked up, a million Characters written and scanned, 500 000 integers
sorted, three times each): *sends* are `kajo run`'s `sends` (every send
through the method cache, special sends that fell back included), *block
values* the `value`/`value:` dispatches, *bytecodes* the plain instructions
the counting build (`-DKAJO_COUNT_OPCODES`) dispatched with each fused one
counted as two, *cycles per bytecode* the release run's `workerCycles`
(median of three) over them. *Net* is the median less the runtime's empty
program (Kajo 43 to 44 ms, Pharo 58 to 59 ms); without it Pharo's stream
part (0.11 s) is half start-up.

Before (1a6a1b8):

| part | Kajo s | Pharo s | ratio | net ratio | sends / element | block values / element | bytecodes / element | cycles / bytecode |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| OrderedCollection | 0.493 (0.490–0.501) | 0.297 (0.295–0.301) | 1.66 | 1.89 | 2.00 | 3.00 | 78.0 | 6.33 |
| Dictionary | 3.174 (3.165–3.203) | 1.158 (1.154–1.179) | 2.74 | 2.85 | 152.6 | 10.07 | 1496.6 | 11.59 |
| stream | 0.860 (0.853–0.862) | 0.112 (0.108–0.114) | 7.70 | **15.47** | 8.00 | 2.00 | 117.0 | 7.75 |
| sort | 1.885 (1.883–1.890) | 0.457 (0.453–0.462) | 4.13 | 4.63 | 3.03 | 18.28 | 788.9 | 5.22 |
| whole program | 6.258 (6.239–6.270) | 1.613 (1.605–1.622) | **3.88** | 4.00 | | | | |

After (0c8e48a):

| part | Kajo s | Pharo s | ratio | net ratio | sends / element | block values / element | bytecodes / element | cycles / bytecode |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| OrderedCollection | 0.491 (0.487–0.505) | 0.297 (0.297–0.302) | 1.65 | 1.88 | 2.00 | 3.00 | 78.0 | 6.35 |
| Dictionary | 1.691 (1.681–1.736) | 1.166 (1.148–1.174) | 1.45 | 1.49 | 56.8 | 4.62 | 780.9 | 11.63 |
| stream | 0.525 (0.518–0.534) | 0.111 (0.111–0.112) | 4.73 | **9.23** | 5.00 | 2.00 | 67.2 | 8.05 |
| sort | 1.882 (1.873–1.889) | 0.458 (0.451–0.466) | 4.11 | 4.61 | 3.03 | 18.28 | 788.9 | 5.22 |
| whole program | 4.452 (4.433–4.506) | 1.609 (1.598–1.622) | **2.77** | 2.84 | | | | |

Whose part it was, against the JIT's 5.5 to 6 on fib, dispatch and arith:

- **stream: the library's** (net 15.5). A `nextPut:` sent `isCharacter`,
  `encode:at:` and `max:` beside itself, `contents` and `grow` copied byte
  by byte with an `at:` and an `at:put:` each, and `String>>do:` sent
  `scalarAt:` and `scalarSizeAt:` per Character. Parts 3 and 4 took it to
  9.2; what is left is five sends an element (the program's `Character
  value:`, `nextPut:`, `encode:at:`, `scalarAt:`, and `c = $e` falling back
  from the special send), which a kernel change cannot remove.
- **Dictionary: below the ratio, but mostly not dictionary.** Timed in
  pieces (programs that run only the part's first steps, one worker, on
  1a6a1b8): 1786 ms of the part's 3131 were
  the keys' `printString` (105 sends a number: a WriteStream, one
  `scalarAt:` and a `nextPut:` per digit, `contents`, and `String>>reversed`
  through a second stream), about 440 ms interning (200 000 Symbols, each a
  stop of its own, 119 to 124 ms of stops in all), about 600 ms of puts
  with their growth and about 250 ms of lookups. Pharo's part is slow too
  (1.1 s, its interning), so the ratio hides that the library spent most of
  Kajo's time printing integers.
- **sort and OrderedCollection: the interpreter's** (4.6 and 1.9).

### Part 2: ByteArray's hash and equality

Primitives 121 (`sameBytesAs:`) and 122 (`hash`) take any byte object:
`Machine.isByteObject` (a heap object with the bytes format) in place of
`isText`, through `om.count(of:)`, the one reader of a byte count (large
bytes). The long paths are those of a long String: past `ByteWork.chunk`
(256 KiB) `sameBytesLong` and `byteHashLong`, polled between chunks.
Primitive 120 (`compare:`) and the other text primitives keep `isText`.

- `ByteArray>>=` keeps the class check (`self class == anObject class`), so
  a String or a Symbol never equals a ByteArray in either direction, then
  `sameBytesAs:` (121) whose fallback is the old element-wise loop
  (`super =`).
- `ByteArray>>hash` is 122, the FNV-1a a String's hash is, and says so: a
  ByteArray and a String of the same bytes hash alike, allowed since they
  are never equal. Its fallback `hashOfBytes` is the same FNV-1a in
  Smalltalk (64-bit arithmetic through LargeIntegers), not the old
  `h * 31 + b` loop: a fallback with another function would give one object
  two hashes (a deviation from the brief's "the Smalltalk loops as the
  fallback"; tested equal to the primitive).
- Tests: `ByteArrayTest` (new, five tests: equal and unequal, different
  lengths, empty, against Arrays, nil and integers, a String and a Symbol
  never equal in either direction, the hash equal to `hashOfBytes` on
  empty, 0, 255 and mixed bytes and equal to a String's, ByteArrays as keys
  of a Dictionary and a Set, 300 000 bytes past a chunk); the VM test
  `aByteArrayPastAChunkIsComparedAndHashedPolled` (a ByteArray of four
  chunks and five bytes and its copy compared and both hashed: the bytes
  and polls of three polled passes and a longest stretch of at most one
  chunk, the bound the long String tests use; it fails on 1a6a1b8, where
  121 failed for a ByteArray). The extreme-integer test is unchanged (no
  integer arguments). The program has no ByteArray hash or equality, so
  no part moved.

### Part 3: the WriteStream path

Sends per `nextPut:` of a Character on a String stream, counted by
programs that do only that (`sends` over a million calls, the `nextPut:`
itself included): **4 before, 2 after**. The text test was already decided
once per stream (the `isText` instance variable); what changed:

- `nextPut:` on a String stream is the encoding primitive (128) alone; its
  failure (no Character, or no room) goes to `nextPutGrowing:`, which
  raises the old error or grows and retries. `isCharacter` left the path.
- `readLimit` is no longer kept on every put: `WriteStream>>readLimit`
  brings it up to `position` and answers it, and every method that reads it
  or moves `position` back reads it through that (`atEnd`, `position:`,
  `reset`, `skip:`, `ReadWriteStream>>contents`); `max:` left the path.
  `contents` (up to `position`), `position:` (within what was written) and
  `reset` (what was written stays readable) keep their meaning,
  `StreamTest>>testWriteStreamPaths` checks each.
- The grow check of a non-text stream is the one comparison it was;
  `grow` is `growTo:`, which doubles until the size fits and copies with
  one `replaceFrom:to:with:startingAt:` (primitive 38 for an Array or a
  ByteArray); `contents` copies the buffer with `copyFrom:to:` (38) and
  validates once (130) instead of an `at:` and an `at:put:` per byte.
- `nextPutAll:` of a String or Symbol on a String stream, and of an Array
  or a ByteArray on a stream over the same class, grows once and copies
  with primitive 38; anything else goes element by element as before.
  Sends for `nextPutAll: 'hello'`: 9 before, 4 after.

| a million … | before ms | after ms | sends before | sends after |
|---|--:|--:|--:|--:|
| `nextPut: $a` | 123.7 | 58.0 | 4 000 119 | 2 000 194 |
| `nextPutAll: 'hello'` | 551.9 | 119.7 | 9 000 122 | 4 000 140 |
| `nextPut: $a`, then 11 `contents` of the megabyte | 454.5 | 67.0 | | |

(`contents` of a megabyte: about 30 ms before, under 1 ms after.) Found
on the way: `PositionableStream>>skip:` on a non-text stream sent
`max:min:`, which no class understands; it is `(… max: 0) min:` now.

The oracle held: the kernel tests (205 before, 211 after with the new
ones) and the tools' 241 tests pass, and the image's Tonel writer, now
writing through the changed WriteStream, writes `kernel/` and `tools/` back
byte for byte (`scripts/canonical-tonel.sh --check` exits 0 with no file
listed, before every kernel commit and on the final one).

The stream part after part 3: 0.860 to 0.580 s, net ratio 15.5 to 10.0;
and, through `printString`, the Dictionary part 3.174 to 2.859.

### Part 4: what part 1 pointed at

Two kernel changes, each with its row (Kajo s, median of five; the other
parts did not move):

| change | part | before | after | sends / element before → after |
|---|---|--:|--:|--:|
| part 3 (ea9e2fe) | stream | 0.860 | 0.580 | 8.0 → 6.0 |
| part 3 (ea9e2fe) | Dictionary | 3.174 | 2.859 | |
| `Integer>>printString:` (ea9b7dc) | Dictionary | 2.859 | 1.711 | → 56.8 |
| `String>>do:` (0c8e48a) | stream | 0.575 | 0.525 | 6.0 → 5.0 |
| all | whole program | 6.258 | 4.452 | |

- `Integer>>printString:` counts the digits, writes them from the right
  into a ByteArray and makes the String once: 9 sends a number against 105
  (600 000 numbers: 1786 ms before, 1430 after part 3, 356 after). A base
  outside 2 to 36 is an error (it was a `scalarAt:` failure, or a loop for
  base 1). A LargeInteger is divided twice as often as before (once to
  count); its printing is not in any measured path.
- `String>>do:` sends `scalarCount` (primitive 126, one pass) and when it
  equals `byteSize` (every byte a scalar) runs a `to:do:` with one
  `scalarAt:` an element, without `scalarSizeAt:`.

The Dictionary part is under the interpreter's ratio as a whole, so its
`printString` change goes past the letter of part 4 (see Deviations).
Not changed, with the numbers the open questions ask for: the sort (net
4.6, the interpreter's; 18.3 block activations and 789 bytecodes an
element) and the dictionary probe (after the changes, timed by programs
that add ten lookups of every key: **12.1 sends and 339 ns a lookup with
Symbol keys, 19.8 sends and 464 ns with String keys**; a put 34.7 sends
with its share of the growth). `Symbol asString` is in no part's loop.

### Part 5: after

The tables above: the whole program 6.26 s to 4.45 s, against Pharo 3.88
to 2.77 (net 4.00 to 2.84); no part slower (OrderedCollection 0.493 and
0.491, sort 1.885 and 1.882, within each other's ranges).

The scripted session (`mode=devsession classes=2000 load=none`, the Mac
shell built at 1a6a1b8 and at 0c8e48a, five sessions each interleaved,
Mac to Mac, `scripts/devsession-report.py`):

| | before | after |
|---|--:|--:|
| `class.hierarchy` round trip p50 | 258.9 [240.4–265.9] ms | **233.9** [224.2–248.1] |
| `package.selectors` round trip p50 | 307.6 [299.5–312.9] ms | **290.0** [287.0–319.1] |
| session seconds | 4.3 [4.3–4.4] | 4.3 [4.2–4.3] |
| frames missed (of about 515) | 39 [38–47] | 44 [39–47] |
| open, populate (pushed), select 10 (steps, ms) | 266, 309, 185 | 261, 286, 194 |

Both requests are faster; `select.10` is within its range (169 to 202
before, 175 to 205 after) (module 10's row, 335 and 457 ms, was taken on
another day's build; these ten sessions are the comparison). The frames
missed overlap.

### The A/B and `interpret`

`scripts/ab.sh 1a6a1b8` (aligned `-enable-testing` release builds of both
sides, five interleaved runs, 1 and 8 workers, checksums equal in every
row; the Smalltalk kernels' images are built from each side's own
`kernel/`):

| kernel | workers | base ms | head ms | ratio | base cycles/send | head cycles/send | cycles ratio | instructions ratio | checksums |
|---|--:|--:|--:|--:|--:|--:|--:|--:|---|
| alloc | 1 | 2891.7 (2885-2902) | 2897.5 (2895-2910) | **1.002** | 77.0 | 77.1 | 1.002 | 1.000 | same |
| alloc | 8 | 447.2 (440-450) | 452.2 (444-457) | **1.011** | 86.1 | 86.7 | 1.006 | 1.001 | same |
| arith | 1 | 1829.8 (1823-1836) | 1825.0 (1822-1829) | **0.997** | - | - | 0.999 | 1.000 | same |
| arith | 8 | 250.7 (247-254) | 246.7 (246-251) | **0.984** | - | - | 0.992 | 0.999 | same |
| fib | 1 | 1382.7 (1378-1392) | 1384.8 (1382-1389) | **1.002** | 58.2 | 58.2 | 1.001 | 1.000 | same |
| fib | 8 | 178.6 (177-195) | 194.0 (180-200) | **1.086** | 57.9 | 59.1 | 1.021 | 1.002 | same |
| ivars | 1 | 1819.1 (1813-1829) | 1824.4 (1816-1826) | **1.003** | 95328.4 | 95409.0 | 1.001 | 1.000 | same |
| ivars | 8 | 243.5 (233-254) | 236.5 (233-240) | **0.971** | 95798.8 | 94603.8 | 0.988 | 0.999 | same |
| sends | 1 | 1675.2 (1662-1676) | 1666.0 (1662-1676) | **0.995** | 70.0 | 70.0 | 1.000 | 1.000 | same |
| sends | 8 | 225.9 (213-242) | 235.4 (217-242) | **1.042** | 70.2 | 71.3 | 1.016 | 1.002 | same |
| st-closures | 1 | 3214.0 (3196-3216) | 3212.9 (3203-3216) | **1.000** | 44905.8 | 44882.3 | 0.999 | 1.000 | same |
| st-closures | 8 | 435.5 (418-445) | 418.2 (409-432) | **0.960** | 45248.9 | 44654.1 | 0.987 | 0.999 | same |
| st-ivars | 1 | 1820.7 (1814-1826) | 1819.9 (1816-1831) | **1.000** | 190464.5 | 190623.0 | 1.001 | 1.000 | same |
| st-ivars | 8 | 242.0 (232-254) | 249.6 (242-251) | **1.031** | 190033.1 | 192054.0 | 1.011 | 1.001 | same |
| st-sends | 1 | 1392.5 (1390-1398) | 1404.4 (1399-1408) | **1.009** | 117.0 | 117.3 | 1.003 | 1.000 | same |
| st-sends | 8 | 185.1 (179-189) | 180.8 (179-186) | **0.977** | 117.1 | 116.8 | 0.997 | 1.000 | same |
| storeheavy | 1 | 2117.3 (2110-2125) | 2116.7 (2109-2119) | **1.000** | 36947.2 | 36977.7 | 1.001 | 1.000 | same |
| storeheavy | 8 | 279.9 (271-295) | 272.3 (271-280) | **0.973** | 37137.7 | 36764.8 | 0.990 | 0.999 | same |

At one worker every kernel is 0.995 to 1.009 with instruction ratios of
1.000; every range overlaps but `st-sends` (1390–1398 against 1399–1408,
1.009, a Smalltalk kernel whose image holds the changed kernel classes, so
its methods sit elsewhere). At eight workers the ratios scatter both ways
(0.960 to 1.086) with overlapping ranges in every row and instruction
ratios of 0.999 to 1.002: the eight-worker noise earlier modules saw (0.940
to 1.080), on kasm kernels (`fib` 1.086, `sends` 1.042, `ivars` 0.971) that
run no changed code at all.

`interpret` (the A/B's own objects, `Dispatch.o` of both sides): 1817
lines of disassembly each, identical without even normalising addresses
(the whole object's disassembly does not differ). `just arc-check` passes:
`interpret` 1403 instructions, one jump table, no retain or release on any
checked path; `stringPrimitive` 1647 instructions, ARC 0, now calling
`sameBytes`, `byteObjectHash` and the two long paths for any byte object.


### The gates

`just check 1a6a1b8` on 0c8e48a (the final code commit; tier core, chosen by
`Sources/KajoVM/ObjectModel/Strings.swift`; Apple Swift 6.4.2 first on
PATH), run last, with nothing else of ours running, its output kept by the
main session (`collspeed/check/`):

```
2026-11-08 23:07:10 0c8e48a check-tier core: 25 files from 1a6a1b8...HEAD (1a6a1b8...0c8e48a) and the working tree
2026-11-08 23:07:10 0c8e48a start clean-build (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-08 23:07:33 0c8e48a end clean-build rc=0 23s
2026-11-08 23:07:33 0c8e48a start swift-test (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-08 23:14:26 0c8e48a end swift-test rc=0 413s
2026-11-08 23:14:26 0c8e48a start swift-test-load (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-08 23:22:40 0c8e48a end swift-test-load rc=0 494s
2026-11-08 23:22:40 0c8e48a start tsan (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 00:10:18 0c8e48a end tsan rc=0 2858s
2026-11-09 00:10:18 0c8e48a start tsan-load (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 01:05:26 0c8e48a end tsan-load rc=0 3308s
2026-11-09 01:05:26 0c8e48a start ios-check (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 01:05:40 0c8e48a end ios-check rc=0 14s
2026-11-09 01:05:40 0c8e48a start arc-check (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 01:05:46 0c8e48a end arc-check rc=0 6s
2026-11-09 01:05:46 0c8e48a start golden (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 01:06:57 0c8e48a end golden rc=0 71s
2026-11-09 01:06:57 0c8e48a start test-release (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 01:08:32 0c8e48a end test-release rc=0 95s
2026-11-09 01:08:32 0c8e48a start model-check (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 01:08:53 0c8e48a end model-check rc=0 21s
2026-11-09 01:08:53 0c8e48a start soak (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 01:10:05 0c8e48a end soak rc=0 72s
2026-11-09 01:10:05 0c8e48a start fuzz-kasm (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 01:20:43 0c8e48a end fuzz-kasm rc=0 638s
2026-11-09 01:20:43 0c8e48a start fuzz-snapshot (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 01:30:47 0c8e48a end fuzz-snapshot rc=0 604s
2026-11-09 01:30:47 0c8e48a start fuzz-syntax (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 01:40:56 0c8e48a end fuzz-syntax rc=0 609s
2026-11-09 01:40:56 0c8e48a start fuzz-protocol (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 01:51:06 0c8e48a end fuzz-protocol rc=0 610s
2026-11-09 01:51:06 0c8e48a start apps (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 01:53:02 0c8e48a end apps rc=0 116s
2026-11-09 01:53:02 0c8e48a start kernel-test (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 01:54:15 0c8e48a end kernel-test rc=0 73s
2026-11-09 01:54:15 0c8e48a start new-check (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 01:57:18 0c8e48a end new-check rc=0 183s
2026-11-09 01:57:18 0c8e48a start ab (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 02:02:36 0c8e48a end ab rc=0 318s
2026-11-09 02:02:36 0c8e48a start matrix-mac (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 02:16:04 0c8e48a end matrix-mac rc=0 808s
2026-11-09 02:16:04 0c8e48a start matrix-iphone (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 02:30:27 0c8e48a end matrix-iphone rc=0 863s
2026-11-09 02:30:27 0c8e48a check-tier done core failed=0 12197s
```

Every gate passed in 12 197 s. `swift test` 394 + 121 tests;
ThreadSanitizer alone and under twelve busy loops 394 + 121 with 0
reports; the kernel tests 211 of 211; the four fuzzers with "libFuzzer
build: ok" at 2.18 (kasm), 3.19 (snapshot), 0.80 (syntax) and 1.76
(protocol) million runs in 601 s; `just arc-check` as above. The gate's
own A/B against 1a6a1b8 read 0.983 to 1.020 at eight workers but
`st-closures` and `st-sends` (1.039, overlapping ranges) and 1.000 to
1.005 at one with every range overlapping. The Mac matrix (7 workers):
0 launches failed, 0 checksums wrong; the rows missing frames are the
known ones: the ring under the stop-the-world young mode (169 to 206
frames behind 8 to 10 counted soft-limit fallbacks with compacting full
collections of 200 to 215 ms, as in sweep-stop's and the interpreter
module's rows), the hog with the budget off (1192 by design), and the
matrix's first idle launch of the freshly built shell (272 frames, no
stop, no fallback: the unexplained first-launch row AGENTS.md records). The
iPhone matrix (5 workers): 0 launches failed, 0 fallbacks, frames missed
only by the ring under the stop-the-world young mode (2, 4 and 5 frames
behind scavenges of 14.5 to 18.8 ms) and the hog with the budget off.


### Deviations

- Part 4's `printString` change is in the Dictionary part, which is under
  the interpreter's ratio (2.85 net). The part's time was 57 percent
  `printString` and its 105 sends a number were the stream's (part 3's
  object); the change is a kernel algorithm with its row. If the owner
  reads part 4 strictly, ea9b7dc reverts on its own.
- `ByteArray>>hash`'s fallback is FNV-1a in Smalltalk (`hashOfBytes`), not
  the old loop, so that the fallback and the primitive agree. The hash of
  every ByteArray changed; images are rebuilt from sources.
- The brief names `ByteArrayTest` and `WriteStreamTest`: there were none.
  `ByteArrayTest` is new; the WriteStream's tests are `StreamTest`'s, with
  `testWriteStreamPaths` added.
- Part 1 adds net times (less an empty program) beside the whole-process
  times the comparison uses; the ratios are given both ways.
- The per-part table in `docs/performance/README.md` section 5 is a
  hand-written block below the generated one (the module's choice);
  `perf-report.py` is unchanged and `just perf-report` leaves the block.
- `PositionableStream>>skip:` fixed (a bug found, not asked for).

### Not done

- The stream part's remaining gap (net 9.2): five sends an element, none
  of them the library's to remove without a primitive or the interpreter.
- `String>>reverseDo:`, `keysAndValuesDo:` and `reversed` still step with
  `scalarSizeAt:` or `previousBoundary:`; no part runs them now.
- The Dictionary's probe loop keeps its three hooks (`hashFor:`,
  `equal:to:`, `keyOf:`) and `at:` its block; the part is under the ratio.
- No device run (the brief asks for none beyond the core tier's matrix).

### Open questions for the owner (built as recommended)

1. `Symbol asString` and `String asSymbol` through the primitives
   directly? Recommended yes only if a hot loop shows them: none of the
   four parts sends `Symbol asString` (`asSymbol` is already primitive
   129). Left as it is.
2. A sort primitive for Arrays of SmallIntegers in the default order? The
   sort is not past the interpreter's ratio (net 4.63 before, 4.61 after);
   it would remove about 789 bytecodes and 18.3 block activations an
   element. An app sorts names with a block (`sort:` on Strings), which
   such a primitive would not take. Not built.
3. The dictionary probe as a primitive for identity keys? The part is at
   net 1.49 after; a Symbol lookup is 12.1 sends (339 ns), a String one 19.8
   (464 ns); String keys compared with `=` are the app's case and an
   identity primitive would not take them. Not built (the owner's
   2026-11-08 decision).
