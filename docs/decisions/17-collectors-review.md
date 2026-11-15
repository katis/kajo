# The collectors review

The collectors review, `docs/modules/collectors-review.md` (2026-11-06): the
first external review of modules 1 and 4 to 7 (pull request 1, 54 files)
found nine things and all nine are fixed, each with a test that fails on the
starting commit: every primitive that reads a slot a program could make weak
keeps its referent alive while a cycle marks (the array copy, `instVarAt:`,
`slotAt:`, `shallowCopy` and, found beside them, the symbol table's bucket
growth had no keep-alive barrier; the array copy records a weak source's
referents in a pass before the copy, so every other copy runs the old loop:
1.011 with a cycle marking, where a check per slot cost 1.068); no primitive
traps on an extreme SmallInteger (the array copy and `basicNew:` did
arithmetic before their bounds checks, two Mac shell view wrappers took any
count), with a seeded test of 840 calls and an extreme argument in the
make-and-run fuzz mode; the collectors' logs are rings of
`VMConfig.logCapacity` records (65 536, 4096 in the shells' demo and
developer modes) with running totals and a dropped count; marking sets and
clears only bit 0 of the shared barrier word (it stored the whole word and
erased module 7's count, so the young stress flag stopped stressing after
the first cycle; no deletion record was ever lost, because stops wait for
open young collections), with a stop verifier on the word and a
`youngBarrierAlwaysOn` random-program configuration; a reshape runs module
4's hook before it lists instances; the object memory releases every
reservation when a later one fails and an Image whose boot fails destroys
its memory; one `bodyBytes`, one pair of cache-line helpers, one `copyBody`;
bench within noise and `interpret` identical; the owner kept the
stop-verifier assertion in every random-program configuration and the
fuzzer's second run (2026-11-06), and the apps keep 4096 records per log
until a tool reads them.
