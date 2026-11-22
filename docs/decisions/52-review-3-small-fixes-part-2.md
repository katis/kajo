# The third review's small fixes, part 2

Briefed by the main session on 2026-11-21
(`docs/modules/review-3-small-fixes-part-2.md`, 8c24c05) on the owner's
"Small safe fixes" and "agreed on questions" of 2026-11-20 and "Yes, brief
it" of 2026-11-21. Built overnight by one agent in seven commits, 5e10684
to 777e896; the last commit that changes code is aeecb55. A core-tier
module. Toolchain: swift.org 6.4.2, first on PATH. Work files:
`~/kajo-scratch/review-3-part-2/` (`S/` below).

## What was measured first (part 1)

| item | finding | starting position | result |
|---|---|---|---|
| 1 | `interpreter.A2` | right | with the barrier word moved to `flag + 3` every native gate passed and the layout hash was equal (`S/broken/flag3-summary.txt`) |
| 2 | `interpreter.M1` | right | `floats` made 120 million entries of the LargeInteger tier and 30 million `BigInt` arrays (`S/part1/count-floats*.txt`) |
| 3 | `memory.M2` | the slow path right, the gain wrong | 99.89 percent or more of slow-path calls leave at the remembered-bit test; the ceiling is under the base's own spread |
| 4 | `memory.A1` | half wrong | near zero on every load (table below) |
| 5 | `verification.R4` | right | 75 switch fields; the unnamed ones are read by product code |
| 6 | `verification.A1` | wrong | three levels cannot say what `test-release` ran |

Item 3's rule is `S/part1/rule-item3.txt` (2026-11-21 21:43, committed in
5e10684 before its numbers). The brief's cheating build lost objects on 3
of its 4 rows, which the rule had a fallback for. The fallback (cheat B,
sound) against the base, in cycles: `share` 0.9937 at 1 worker and 0.9900
at 8, `ring` 0.9952 and 1.0007, against spreads of 0.0084, 0.0273, 0.0232
and 0.0392 in the same table (`S/part1/cheatb/table.md`). Not built.

`weakOnlyCopies` against the young collections' promotions
(`S/part1/weak/`):

| load | weakOnlyCopies | ycPromoted |
|---|--:|--:|
| kernel tests | 0 | 923 895 |
| the tools' scripted session | 2 | 1 370 041 |
| collections, 1 worker | 0 | 600 009 |
| collections, 8 workers | 0 | 4 800 072 |
| a million Symbols interned and dropped | 0 | 0 |

A Symbol is old at birth, so the last row does not reach the cost. The
counter read 0 in every offload row of both matrices.

## What was built (part 2)

- Item 1. `barrierWordIndex` is the VM's `flag + n` and the layout's
  `FLAG_BARRIER_WORD`; the generator writes frame indexes from `Frame`;
  the generated tables file has 27 `_Static_assert`s of `KResume`,
  `KGroup` and `KModule` against the Swift mirrors. The generated C
  differs only in the constant, the hash, the barrier line and the asserts
  (`S/work/gen-diff/diff.txt`). A module built before this is refused at
  bind (the hash changed).
- Item 2. `smallFloatArith` answers a SmallFloat with a SmallFloat or a
  SmallInteger before any register save, from the special sends
  (`smallFloatSpecial`) and primitives 60 to 69 (`floatPrimitiveQuick`),
  both out of line. `integerArith` returns before `largeArith` unless an
  operand is a LargeInteger. `floats` against 8c24c05, aligned, five runs
  (`S/work/ab-final/table.md`): 3213.0 to 1859.5 ms at 1 worker (cycles
  0.580), 469.2 to 239.8 ms at 8 (cycles 0.535); `smallFloatAnswers=120000000
  largeArithCalls=0` on its run line. The test compares the path with the
  old one over seeded operands (the test switch `noSmallFloatPath`).
- Item 4. The counter only.
- Item 5. `SwitchTableTests`: every field of the six switch structs has a
  row naming its test or its by-hand run; a field with no row fails.
- Item 6. `VerificationLevel` (`off`, `stops`, `all`), applied in one
  function; `--verify-level`; the lines print the level's name.

## The first tier run

`S/check-run1/gates.log`: d3ac36c, `failed=0`, 12375 s. Its A/B had
st-closures 1.044 slower at 1 worker: the first SmallFloat path, inline,
grew `specialSend` from 764 to 1004 instructions and spilled the object
table's base. Seven shapes were measured (the module doc's table); the
final one (two SmallIntegers skip the number test; any other pair tests,
then tries the path out of line) gives st-closures 0.994 and `floats`
0.580 against the first version's 0.427. The speed given up is recorded
there.

## Gates

`S/check/gates.log`, last line: `2026-11-22 06:36:59 aeecb55 check-tier
done core failed=2 12266s`. Twenty gates `rc=0`. Aligned A/B against
ac3b752 (`S/check/ab/table.md`): 0.987 to 1.003 in cycles at 1 worker,
0.982 to 1.018 at 8, checksums the same. `interpret`: 1816 lines in both
builds, 4 differ, each an `adrp` page. Both matrices: 153 rows, 0 failed,
0 fallbacks; the rows that missed frames are the hog rows and the ring
under `stw`, as before. `test-release` prints `verify=all` per part.

The two failures, neither on a test of this module:

- `tsan`: `randomProgramsAgreeWithTheirModel(exhaustedReserve)`,
  RandomPrograms.swift:732, "randomScavenges.take(config) > 0". Alone
  through `gl_gate` the gate passed (`S/check-rerun/gates.log`, 3265 s).
  Counted (`S/work/random-count/`, rule written first): head 0 of 5,
  8c24c05 2 of 5 on the same check in another configuration. Thin on the
  starting commit.
- `tsan-load`: `theToolsDevelopTheImageTheyRunIn`, "nil does not
  understand #beginsWith:" at the step `compiledTypedThroughTheBrowser`.
  Alone through `gl_gate` the gate failed again on the same line. Counted
  (`S/work/tools-count/`, rule written first): head 1 of 2, 8c24c05 0 of
  2; over every run under that condition the head failed 3 of 4. The
  cause is not established. The main session read the diff for a
  mechanism and found none (a `ShellVM` in a debug build runs the same
  verifiers as before); that is a reading, not a proof. It did not run
  the gate a third time. The test failed 1 of 2 on the
  previous module's starting commit under `tsan`.

Gate times against 2c13ed3: `swift-test-load` 847 s (818), `tsan` 3199
(3210), `tsan-load` 4312 (4262), `test-release` 193 (182), `arc-check` 59
(48), the matrices 790 and 857 (813 and 870). Eleven new tests in the VM
bundle; the slowest under the sanitizer and load takes 27 s.

## The main session's check

Read: the whole product diff, both `gates.log` files, the rule and its
time, the bound's table, both A/B tables, the quoted runs
(`S/work/quotes.txt`), the counted runs' summaries, `shell-report.py --bar`
over both matrices, the dry run ("tier: core"), the tree (clean) and the
process list (nothing of Kajo alive). Not run again: any gate, the broken
variants, the tests on the starting commit.

## Deviations

- Item 6: `test-release` gained the stop and schedule verifiers. The
  brief's bar said every gate would verify exactly what it did; the brief's
  three levels could not keep that. The brief's error.
- Item 3's bound came from the rule's fallback.
- `weakOnlyCopies` and `ycPromoted` are also in `kajo test`'s summary and
  the devsession line; `specialSendTier` and `floatsBoxed` are on the run
  line.

## Not done, not verified

- Item 3 and the weak pass. A runner for the by-hand variants.
- The native engine and the devices on the final SmallFloat shape (the
  tier's native gates and matrices ran; `floats` was not measured there).
- `smallFloatSpecial` and `floatPrimitiveQuick` are not on `arc-check`'s
  list.
- That a generated app rebuilds its native module after the hash change
  (`new-check` builds fresh).
- The cause of either test failure.

## Found, not this module's

- Eight workers that each intern a million Symbols and drop them: every
  `asSymbol` fails after 390 s (`S/part1/weak/symbols-8*.txt`), on 8c24c05
  too. One worker and a million pass with `cycles=0`: a million old
  Symbols never start a marking cycle.
- The agent's reading of the tools failure, not checked: the type service
  selects over Dictionary keys its background Process is changing.
- `script -q /dev/null` fails without a terminal in an agent's shell.

## Open questions

1. `test-release` at `all`. Recommended: keep; the alternative is a
   fourth level for one gate, and the stop verifiers cost nothing
   measurable (193 s against 182).
2. The weak pass for the concurrent young collector. Recommended: no
   module; the counter stays and the question opens again if a row shows
   a share.
3. The by-hand broken variants in the weekly run (three in the switch
   structs, 36 s after a 39 s build). Recommended: a later module.

The release default of `kajo run` stays `off` (no question; as before).
