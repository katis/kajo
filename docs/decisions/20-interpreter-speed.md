# The interpreter-speed module

The interpreter-speed module, the last of the VM core, built 2026-11-07
(`docs/modules/interpreter-speed.md`, ADR 0009's Built (interpreter speed)
note): measured first (`kajo run` reports the workers' own cycles and
instructions from the per-thread counters; a counting build,
`-DKAJO_COUNT_OPCODES`, writes dynamic and static opcode singles, pairs and
triples, none of it in the product build): fib cost 71.3 cycles per send and
7.13 per bytecode on the global method cache, `sends` 109.6 and `st-sends`
193.7 per send, `arith` 106.8 per iteration; part 1 (the send path) was
measured and discarded step by step: a build that trusts the cache line
without comparing put a per-site inline cache's ceiling at 2 percent,
removing the poll countdown entirely at 1.1, and a leaner activation (built
two ways in four register layouts) won 8 percent on fib alone but spilled
`true` and `false` and lost 6 to 8 on `arith` and `ivars`, adding nothing
over fusion; part 2 kept: 17 fused instructions (opcodes 50 to 66) chosen
from the counts (`push_temp`/`push_self` with `push_temp`/`push_int`,
`push_int` with `add`/`sub`, `add`/`sub` with `store_temp`, `store_temp
jump`, `dup store_temp`, `pop push_temp`, and
`lt`/`gt`/`le`/`ge`/`eq`/`identical` with `jump_if_false`), where a fused
opcode replaces only the first instruction's opcode byte so offsets,
operands, jump targets, the source map, saved pcs and stepping are those of
the plain code and a fast path that does not apply runs the first part alone
and dispatches the intact second; the peephole `fuseBytecodes` in
`MethodBuilding` fuses every made method (idempotent, never an extended
instruction; `noFusion` test switch), the verifier's one new rule is that
the second part follows plain and unextended, kasm reads the mnemonics,
primitive 166 `plainBytecodes` lets the compiler tests and
`CompiledCode>>matches:` compare plain code, the random programs gained a
`plainBytecodes` configuration and the kasm fuzzer a seed of every mnemonic;
part 3 kept: `at:` on an Array with an in-bounds SmallInteger index, `isNil`
and `notNil` inline in the loop (`st-sends` 0.888 against part 2); the
aligned A/B against b04acba (5 interleaved runs, 1 and 8 workers, checksums
equal): cycles per send fib 0.815 (58.1 per send), `sends` 0.638, `st-sends`
0.605, `arith` 0.717 per iteration, `st-closures` 0.845, `storeheavy` 0.878,
`ivars` 0.924, `alloc` 0.983, nothing slower than 1.008 in wall time,
dispatches 0.62 to 0.84 of the plain count; `interpret` 1320 to 1816
instructions, still one jump table and one indirect branch, the register map
and the seven-instruction dispatch identical; the iPhone 13 Pro at 1 worker
fib 0.811, `sends` 0.832, `arith` 0.720, `st-sends` 0.605; the shells'
matrices on the iPhone (5 workers) and the Mac (7): 0 fallbacks and 0 frames
missed in every row but the ring under the stop-the-world young mode (iPhone
0, 1, 5 at thermal serious behind 13.6 and 17.3 ms scavenges, 9a's 1 to 4;
Mac 289 to 316 against the starting commit's 193 to 282 in seven interleaved
launches each, every miss a counted soft-limit fallback's compacting full
collection of 185 to 200 ms, 26 to 32 of them against 20 to 28, because the
faster mutators cross the soft limit with no cycle running more often, an
open question) and one Mac idle launch, the matrix's first, missing 595
frames behind a 4.97 s gap with no stop in it that six more launches did not
repeat (unexplained); the gates on ae1b0d6 read 385 + 115 Swift tests, 205
kernel tests and the four fuzz targets one after another at 0.90 to 3.33
million runs; 120 new `unsafe` lines; not done: fused sends and triples,
inline `size` and `class`, the iPad rows, misprediction counters (root); its
three open questions await the owner (image version 6 kept, the oracle ring
row, fused sends as a follow-up); with it the VM core is done and the gate
tiers of Verification apply; the comparison re-run the same evening
(`docs/performance/README.md` section 1a, baseline kept as
`experiments/runtime-comparison/bench-raw-before-interpreter.txt`): every
other runtime within 1 percent of its baseline, Kajo fib 0.82, dispatch 0.64
and 0.61, arith 0.74 and 0.76, binarytrees 0.97 and collections 0.88 of
before, now ahead of Java `-Xint` on fib, level with Lua 5.4 on dispatch and
within 3 percent of Ruby on arith, LuaJIT's interpreter 1.5 to 2.1 times
faster where it was 2.3 to 2.6.
