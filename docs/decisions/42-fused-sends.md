# Fused sends, measured first

A follow-up of the interpreter-speed module, 2026-11-17
(`docs/modules/fused-sends.md`; one sitting; commits c434e23, 78e8ff0 and
4607197, the doc only). The owner's answer of 2026-11-15 was "Measure
first." The module stopped after part 2: nothing passed the rule, nothing
was built, no code changed. Work files are in `~/kajo-scratch/fused-sends/`.

## The counts (part 1, on 7934a55)

A push followed by a send (`push_temp`, `push_self`, `push_lit`,
`push_ivar`) as a share of dispatches (`part1/table.md`): `sends` 10.17
percent, `st-sends` 5.08, `alloc` 12.12, `walk` 12.15, the collections
program 0.90, the kernel tests 4.07, the kernel and tools tests 4.11; `fib`,
`arith` and `closures` 0. In the image `push_temp send` is 2803 sites (4.97
percent of instructions) against 2.02 percent of the kernel tests'
dispatches.

## The rule

Committed in the doc at 15:06:04 (78e8ff0); the first cheating measurement
started at 15:09:59 (`part2/ab-all4.txt`). Build only if a cheating build
gains 5 percent of cycles or more on two of `sends`, `st-sends`, `fib`,
`closures` and the kernel tests, checksums equal, and no golden kernel's
cycles ratio is above 1.010 at 1 or 8 workers.

## The cheating builds (part 2)

Two builds from 78e8ff0, never committed (`part2/cheat-{a,b}.diff`), all
four pairs fused: (a) through the one inline send, (b) each with an inline
send of its own. Aligned, five interleaved runs with the order rotated,
twelve golden kernels at 1 and 8 workers and the kernel tests, checksums
and 249 of 249 tests equal on every side (`part2/table-all4.md`). Cycles
gained at 1 worker:

| | sends | st-sends | fib | closures | kernel tests | alloc |
|---|--:|--:|--:|--:|--:|--:|
| (a) shared send | 4.4 % | 2.9 % | 0.2 % | 0.2 % | 0.6 % | 2.4 % |
| (b) own send | 3.2 % | 3.2 % | 0.3 % | -4.1 % | 0.3 % | 4.0 % |

Neither passes. A removed dispatch saved 7.4 instructions and 2.7 to 3.3
cycles. The loop kept one jump table and one indirect branch in both, with
no retain or release (`part2/disasm/`), but (a), 24 instructions longer,
spilled `true` and one base register, and (b), 864 longer with five inline
sends, spilled `true` and `false`.

At 8 workers the cycle ratios are noise on this machine (`floats` spans
0.969 to 1.175 within (a)'s five runs and reads 1.046), so the rule's
second clause could not have been met there by any build; the verdict rests
on its first clause.

## The starting positions

1. Under 10 percent of dispatches: held for the tests, wrong for `sends`,
   `alloc` and `walk`. The ceiling of a few percent held.
2. The gain is the dispatch only: held in instructions; in cycles a
   dispatch was worth more than its instructions (branch prediction).
3. The shared path keeps the registers: wrong.
4. Static counts overstate dynamic ones: held.
5. The workloads are send-bound: held.

## Gates

`just check 7934a55`: "nothing owed: docs only", `rc=0`
(`check/just-check.txt`). Nothing else ran, as the brief says.

## Deviations and not done

- The kernel tests' cycles are the whole `kajo test` process's.
- arc-check's reading was applied by the agent's own script to the
  cheating trees.
- No pair was measured alone (the rule), no triples, no device runs.

## Open questions

1. Close fused sends as measured? Recommended: yes. The best bound is 4.4
   percent on one kernel and 0.6 percent on the kernel tests, and a Release
   app runs native code. Reopen only if a workload where the interpreter
   matters is shown to be bound by the dispatch between a push and a send.

## 2026-11-17, the owner's answer

"Yes, close it". Fused sends is closed as measured; the reopening
condition is the one in question 1.
