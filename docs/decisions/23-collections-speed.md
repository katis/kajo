# Collections speed

Collections speed, built 2026-11-08 to 09
(`docs/modules/collections-speed.md`, the owner's choice of 2026-11-08: the
library, measured first, no dictionary-probe primitive): the comparison's
`collections` program split into four kernels of its own plus an empty
program for the start-up
(`experiments/runtime-comparison/programs/collections-{oc,dict,stream,sort,empty}`,
`bench.sh`'s `$PARTS`, the checksums adding up to the whole's), five
interleaved rounds against Pharo 12 at thermal nominal with the sends from
`kajo run` and the counting build: before, net of start-up,
OrderedCollection 1.89 times Pharo (2.0 sends per element), Dictionary 2.85
(152.6 sends per element, 57 percent of it `printString`), the stream 15.5
(8.0 sends per character) and the sort 4.63 (3.0), so the stream was the
library's and the rest were under the interpreter's 5.5 to 6; the one VM
change: primitives 121 and 122 take any byte object (`Machine.isByteObject`;
the long paths poll as a long String's), `ByteArray>>=` keeps the class
check and compares with 121, `ByteArray>>hash` is 122's FNV-1a with the same
function in Smalltalk (`hashOfBytes`) as the fallback, so a ByteArray and a
String of the same bytes hash alike and are never equal;
`WriteStream>>nextPut:` on a String stream is one send, the encoding
primitive 128, with `nextPutGrowing:` on failure, `readLimit` brought up to
date where it is read rather than `max:` on every put, `grow`, `contents`
and `nextPutAll:` of a String, Array or ByteArray copying in one step with
primitive 38 (4 to 2 sends per Character, 9 to 4 per `nextPutAll: 'hello'`,
a million puts 124 to 58 ms, `contents` of 1 MB 30 to under 1 ms),
`PositionableStream>>skip:` on a non-text stream no longer sends an
undefined `max:min:`; `Integer>>printString:` counts the digits and writes
them into a ByteArray from the right with no stream (105 to 9 sends per
number, 1786 to 356 ms for 600 000; a part under the ratio, flagged as a
deviation, kept because printing an Integer is every app's path),
`String>>do:` skips `scalarSizeAt:` when every byte is a scalar; after:
Dictionary 1.49 (56.8 sends per element), the stream 9.23 (5.0 per
character, none removable in the kernel), OrderedCollection and the sort
unchanged within their ranges, the whole program 4.45 s against 6.26 (2.77
times Pharo's 1.61, from 3.88), the per-part table beside the whole-program
row as a hand-written block in `docs/performance/README.md` section 5; the
2000-class scripted session Mac to Mac, five a side interleaved,
`class.hierarchy` p50 258.9 to 233.9 ms and `package.selectors` 307.6 to
290.0 with frames missed overlapping (39 against 44); the round trip
byte-identical on every kernel commit (`canonical-tonel.sh --check`, 172
kernel and 28 tools files); the aligned A/B against 1a6a1b8 0.995 to 1.009
at 1 worker with instruction ratios 1.000 (`st-sends` 1.009 is a Smalltalk
kernel built with the changed classes) and 0.960 to 1.086 at 8 with
overlapping ranges, `Dispatch.o` identical, `just arc-check` passing; `just
check 1a6a1b8` on 0c8e48a, the core tier, every gate in 12 197 s (394 + 121
tests, ThreadSanitizer 0 reports alone and under load, 211 kernel tests, 241
tools tests, the four fuzzers with "libFuzzer build: ok" at 0.80 to 3.19
million runs, the Mac matrix's ring under `young=stw` 8, 8 and 10 fallbacks
and its first idle launch missing 272 frames behind no stop, the fourth
such, the iPhone 0 fallbacks and 2 to 5 frames in the same ring row); not
done: the stream's remaining five sends per character, `String>>reverseDo:`,
`keysAndValuesDo:` and `reversed` still stepping one scalar at a time, the
probe's hooks unchanged, a LargeInteger's `printString` dividing twice as
often; its three open questions built as recommended (`Symbol asString`
left, no part sends it; no sort primitive, the sort is under the ratio and
would remove about 789 bytecodes and 18.3 block activations per element
while apps sort with a block; no probe primitive, a Symbol lookup 12.1 sends
and 339 ns, a String lookup 19.8 sends and 464 ns).
