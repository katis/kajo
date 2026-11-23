# The verifier's two faults

Briefed by the main session on 2026-11-21 (`docs/modules/verifier-faults.md`,
07fcad1) on the owner's "agreed on questions" of 2026-11-20 (the faults
before part 2 of the small fixes; the verifiers in the release-build kernel
gate only) and "Yes, brief it" of 2026-11-21. Built the same day by one
agent in ten commits, d8881cb to a9a09f2; the last commit that changes
product code is 2c13ed3, the last that changes a test b95cf06. A core-tier
module. Toolchain: swift.org 6.4.2, first on PATH.

## What was found

Both causes were named from the verifier's own message, after part 1 made
the message say what each entry is.

Fault 1. The holder was "Array (class 7), old, 4 slots, read-only, pinned",
a made method's literal frame; the referent "OrderedCollection (class 237),
young in 1", the fuzz test's stranger. Primitive 143 makes its frame in old
space and `makeMethodObjects`, shared with the image build, stored each
literal with the raw store. Part 1's table lists every store of primitives
143 to 147, 163, 97 and 98: this is the only one where an old holder can
take a young value. The compiler alone cannot make such a literal (a class
and a Symbol are old; a redefinition promotes everything before it makes
methods; the test `aClassVariableAddedLiveLeavesNoYoungLiteral` passes on
the part 1 commit). Only a program that changes a CompiledCode's literals
after compiling and then makes the method reached it; the kernel's tests do
that once.

Fault 2. `placeKept` (`Nursery/Scavenge.swift`) places a body a scavenge
kept (the promotion reserve's fallback) in another nursery when its own
has no room, and gave the new nursery's bit to the holders already
remembered for the old one. Two kinds of holder were in no set, in the
offloaded mode only (stop-the-world remembers old holders only): young
objects of the old nursery that name the body, and the body's own
references back to the old nursery. A fault since module 7. Forced with the
new test switch `keptAcrossNurseries`: 612 verifier failures in 22 s. Under
the suite's load, by a rule written first, 3 of 3 counted runs of the stall
tests trapped in the full-heap test's offload half, each naming a referent
"kept and moved from nursery 1 to 0"; the third hit the gate run's own
entries 148628 and 148629. Runs 2 and 3 had other work of the module beside
them.

All five starting positions were right.

## What was built

- Fault 1: `MethodHeap.storeLiteral`. The make primitive's heap stores a
  literal through the barrier (`BarrierSite.methodLiteral`); the image
  build's heap keeps the raw store. The barrier writes the remembered word,
  a side table, so the frame's read-only bit is in nobody's way.
- Fault 2: after kept bodies moved across nurseries, `placeKept` scans
  again the survivor log of each nursery that lost a body and the moved
  bodies, and remembers each for the other nurseries it names. Counter
  `keptAcrossHolders` on the run line.
- The nursery verifier's remembered-set message describes holder and
  referent (`describeEntry`: class, old or young with nursery, age and
  tag, slots, read-only, pinned, the remembered word, the lists, a kept
  body's move) and ends with the scavenge counters.
- The verifiers: `kajo test` at the build's level; `KernelTestParts` and
  the stall tests' helper in a release build only, each part printing and
  asserting `verify=on` and `verifies` above 0 there; the debug gates
  `kernel-test` and `tools-test` say `--no-verify`; `ShellVM` stays off.

## Numbers

| What | Value | File (`~/kajo-scratch/verifier-faults/`) |
|---|---|---|
| `kajo test --verify`, release, 262 tests | 5 of 5 passed, 12.99 to 13.26 s, `verifies=2123` | `work/verify-runs/summary.txt` |
| the same, debug | 5 of 5 passed, 346 to 592 s (the first three beside other work) | the same |
| debug kernel run unverified | 117.9 s | the doc, part 4 |
| stall helper verifying in debug | ring 54 to 430 s, full heap 307 to 1347 s; `swift-test-load` 811 to 1861 s | `check-run1/` |
| aligned A/B against 1318518 | 0.992 to 1.006 at 1 worker, 0.946 to 1.044 at 8; the head against itself 0.996 to 1.005 and 0.975 to 1.047 | `check/ab*`, `work/ab-self.txt` |
| `interpret` | 1403 instructions, 0 differing lines | `work/interpret-diff.txt` |

Tests on the part 1 commit (no fix): the made method's young literal fails
in each of its four kinds with the verifier's line, the kept-across test
fails in the offloaded mode (142 to 612 failures) and passes under `stw`;
all pass on the head. Broken variants, both suite tests on switches:
`skipBarrierAt=.methodLiteral` (4 failures naming the frame) and
`keptAcrossWithoutRescan` (1156 failures in debug, 14 to 374 under the
sanitizer and load).

## Gates

`~/kajo-scratch/verifier-faults/check/gates.log`: `2026-11-21 12:28:17
2c13ed3 check-tier done core failed=1 12235s` (the last core run,
a89dd0e: 10884 s). Twenty gates `rc=0`; `tsan` `rc=1` on
`theToolsDevelopTheImageTheyRunIn` ("nil does not understand #beginsWith:",
the shape of the small fixes' Found 3), not a test of this module. Counted
by a rule written first over the compiler tests' bundle under the
sanitizer: head 0 of 2, starting commit 1 of 2 with the same line
(`work/tools-count/summary.txt`); two runs a side say only that the
starting commit fails it too. After the tier only a test file changed
(b95cf06): the agent ran `test-release` again alone (`rc=0`, 118 s, parts
`verify=on verifies=984` and `1151`), and the main session ran `tsan` alone
on a9a09f2 through `gl_gate`: `rc=0`, 3218 s, 473 and 198 tests passed, 0
sanitizer reports (`main-session/check/`). `swift-test-load` and
`tsan-load` were not run again on b95cf06.

Times against a89dd0e: `swift-test-load` 818 s (811), `tsan` 3210 (2898;
aca38de 3230), `tsan-load` 4262 (3653), `test-release` 182 and 118 (121),
`kernel-test` 123 with `verify=off` (108; aca38de 122), the matrices 813
and 870 s for 153 rows (670 and 738 for 147; the six rows are main flips').
Fuzzers: four `build=ok`, 0.76 to 2.85 million runs. Two earlier tier runs
were stopped on the module's own tests and kept (`check-run1`,
`check-run2`).

The bar's columns over every matrix row: Mac 153 rows, 0 failed launches, 0
fallbacks, 0 unjustified, stalls 703 (longest 26.50 ms), longest stop
17.31 ms; iPhone 153 rows, 0 failed, 0 fallbacks, 0 stalls, longest stop
19.21 ms, longest wait for a safepoint 8.84 ms. Frames were missed in six
rows on each (the hog rows by design, the ring under `stw` 16 and 15, the
iPhone's mainload 2).

Verified by the main session from the files: the commits, the clean tree,
the dry run ("tier: core"), every line of `gates.log`, the product diff
read whole, the numbers above from their raw files, no process of Kajo
alive. Run by the main session: the changed `tools-test` gate command once
(356 of 356, `verify=off`, `main-session/tools-test.txt`) and the `tsan`
gate above. Not rerun: part 1's failing tests, the broken variants, the
counted runs.

## Deviations

- The brief's part 4 said `KernelTestParts` and the stall helper at "the
  build's own level"; the owner's answer was "the release-build kernel
  gate only", and they disagree for a debug build. The agent took the
  owner's words: both verify in a release build only, and the debug gates
  say `--no-verify`. The brief was wrong.
- Part 1's tests ran on the part 1 commit, which has the switch they
  need; on 07fcad1 itself fault 1 was reproduced through `kajo test
  --verify`.
- Two of fault 2's three counted runs had extra load.

## Not done

- The verifiers in `ShellVM` and the tools tests (not in the module).
- Why `Smalltalk sourceOf:` answers nil in the tools test that failed the
  sanitizer gate: not looked at. It fails on the starting commit too.
- The young-collection model is unchanged; it has no kept bodies.

## Open questions

1. The verifier levels as built: on in every `kajo test` not told
   otherwise, on in a release build's kernel tests and stall tests, off in
   the debug kernel gates and in `ShellVM`. Recommended: as built; a debug
   kernel run verified costs 228 s more.
2. Fault 1 in a release's notes. Recommended: no; a program had to edit a
   CompiledCode's literals before making the method. Fault 2 could lose an
   object in any app whose promotion reserve ran out with a full nursery,
   in the offloaded mode; recommended: one line in the next release's
   notes.

## The owner's answers (2026-11-23, "Yes, as recommended")

1. The verifier levels stay as built.
2. Fault 1 is not said in a release's notes. Fault 2 gets one line in the
   next release's notes.
