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
