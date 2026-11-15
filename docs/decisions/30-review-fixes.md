# The second review and its fixes, parts 1 and 2

The second review and its fixes, part 1, built 2026-11-10
(`docs/modules/review-fixes.md`, the reports in `docs/reviews/2026-11-10/`):
at the owner's request five Opus reviewers read the whole tree at d78afcc
(collectors, interpreter, kernel, primitives, tools) and found 42 things,
each with its invariant, its path and a proposed test; part 1 built the
critical and high ones and the mediums in the same files, 24 items, every
test run on the starting commit 8a8847d first (22 items fail there, three
tests pass there and are said to, two are the fix's own instrumentation):
primitive 93 refuses to clear the read-only bit of an object pinned for good
and every object the VM makes read-only is pinned for good (a program could
make a verified method writable and rewrite its bytecodes); an object still
being built is hidden from the walks of primitives 167 to 170 by a building
mark on its pending root, and `zeroLongBytes` reads its object's length and
body again after every park (`buildingPauseUs`, `walksSeeBuilding` as
switches); a debug stop of a Process waiting on a Semaphore rewinds its pc
to the wait send by the recorded `waitSendLength`, so proceed waits again
instead of running on unsignalled (the owner's answer); the accept loop
survives a failed `accept` and connections that have not opened a session
are bounded (`ProtocolServer.Limits`: 8 at once, 4096 bytes, 5 s;
`acceptFailures`, `unpairedClosed`); `Connection.send` and `close` enqueue
under the lock and the descriptor is closed by `finish` (`lateWrites`); the
image hears `session.close` for every session it was told of, whoever ended
it; `Transcript` makes its text outside its lock; `retry` unwinds to a
marker of its own (`Exception retryMarker`), `outer`, `pass` and
`retryUsing:` follow ANSI; `Smalltalk registry:` is one reentrant Mutex over
the class-name table, the sources, the pragma index and the handles, each
DevSession has its own, and every rebuilt table is published whole;
primitive 39 exists only behind `VMTestSwitches.slowPeek`; the hosts refuse
a non-finite or out-of-range geometry value (`geometryValue`,
`TextOffsets.swift`); `DevClient` does not resend `evaluate`,
`process.evaluate`, `process.step` and `test.run` by one list
(`notRetried`); `critical:` releases only what it acquired, with a terminate
that lands after a completed wait left for the Process's first poll
(`dequeueLocked`, `runSlice`, the one change near the scheduler); the
protocol's own Process is refused for suspend, step, evaluate and terminate;
JSON duplicate keys by a Set (100 000 keys 0.14 s from 422); 148's temporary
file has a unique name; a project remove never takes a directory; primitives
154 and 160 put a request back when the image cannot allocate
(`failAllocations`); a released `ShellProcess` is refused; pointer copies
poll every 32 768 slots (`PointerWork.chunk`) and the final mark's weak pass
is measured, not bounded (11.1 ns a slot in a debug build, about 186 ms at
the largest Array); `Fraction>>hash` is its `asFloat`'s; 156's resend checks
the traced depth and the marker; a save is refused while an interrupt or a
terminate is pending (`snapshotsRefusedPending`); `interpret` identical but
for the jump table's page offset, `just arc-check` passing, the aligned A/B
against 8a8847d 0.997 to 1.006 at 1 worker and 0.977 to 1.031 at 8 with
instruction ratios 0.999 to 1.001; the first three `just check` runs stopped
at faults of the new tests themselves (a write to a closed socket raising
SIGPIPE in the test process, autoreleased reads never drained under
ThreadSanitizer, twenty connects at once past a listen backlog of 16), each
fixed in the tests; the fourth, `just check 8a8847d` on d59d0fc, the core
tier in 13 216 s, passed every gate (418 + 136 tests, ThreadSanitizer 0
reports, 240 kernel tests headless and on the iPhone, the four fuzzers with
"libFuzzer build: ok" at 0.82 to 3.35 million runs, the Mac matrix's ring
under `young=stw` 188 to 190 frames behind 9 fallbacks and every other row
0, the iPhone 0 fallbacks and 2 to 5 frames in the same row) but
`tsan-load`, where 9d's listener test waited 120 s for the pause-ended
report: `refusing()` sent it to a global queue from under the server's lock
and no thread of the queue ran it under the sanitizer and twelve loops; the
main session fixed the cause (0110f70: the caller that finds the pause over
makes the report after its unlock; the test unchanged) and ran the Swift
tier on it with the two loaded test gates after (`just check d59d0fc` in
4092 s, then `swift-test-load` and `tsan-load`, 4140 s, every gate passing
with 418 + 136 tests, 0 sanitizer reports and the protocol fuzzer at 366 795
runs); not done: the tests part 2 owes (the accept failure injected, the
client side of the late write, 154's put-back alone), a waiting Process
loaded from an image has no wait length, the weak pass in a release build;
its three questions answered by the owner on 2026-11-10 as recommended (the
host decides the project directory in a later follow-up, the unpaired limits
as named, a suspended waiting Process re-waits) and the fourth on 2026-11-10
as recommended (the final mark's weak pass stays in the stop as a documented
limit: in a release build on the mini 0.73 to 0.77 ns a slot, 0.8 ms at 2^20
weak slots and 12.3 ms at the largest WeakArray, so a frame at 120 Hz is
about 11 million weak slots; no read barrier on weak slots and no overrun
counter are built); part 2, built 2026-11-10 to 11 (the same doc, "As built
(part 2)"; the rest of the review, 20 items): the kernel's compiler walks
message chains by loops as the bootstrap does (a chain of 120 000 sends
compiles; it overflowed the request Process's stack), `DevSession>>printOf:`
prints through the new kernel class `LimitedWriteStream` (4000 bytes, cut on
a scalar boundary, an object already being printed is `...`), and no request
is left unanswered: `DevProtocol run:` replies from an `ensure:` block and a
reaper Process, alive only while requests pend and looking every 100 ms,
answers for a request whose Process a VMError ended; one identifier rule,
`IdentifierRule.classify` in KajoVM, called by the bootstrap's scanner
directly and by the kernel's through primitive 171 `Scanner
class>>identifierClassOf:` (the owner's question, built as recommended:
Unicode alphabetic from the host's tables); both Tonel readers skip comments
while looking for a pattern's `[`; primitive 146's specification has a fifth
part, the names after the change of every class at or below a changed one,
required whenever a shape or a pool changes and checked with
`ClassRules.namesProblem` before anything changes; the kernel's generator
refuses as a CompileError at each of the assembler's limits and the make
primitive refuses more than `maxMethodBytes` of bytecode before the verifier
reads it; inlining and integer-literal decisions by SmallInteger-ness and
`<primitive:>` only 1 to 255 once, as the bootstrap decides; the two
compilers compared on a corpus of 154 methods at and past each limit
(`Tests/KajoCompilerTests/Fixtures/compiler-corpus/corpus.txt`, through
`Loader/KernelCompilerProbe.swift`, test and fuzz support only), which found
the bootstrap's assembler accepting 257 temps and a 256-argument block that
the heap verifier refuses (fixed in `Assembler.swift`: the verifier was the
reference there), and under a new fuzz mode (`scripts/fuzz.sh
syntax-kernel`: each input compiled by the kernel's compiler in a VM as well
and the outcomes compared), which found three disagreeing inputs with two
causes (bytes that are not UTF-8 handed to the kernel, and the bootstrap
accepting a comment that is not UTF-8; `parseMethod` validates the whole
source) and then nothing in 47 082 and 45 163 runs of 600 s; a temporary of
an inlined loop body that no closure captures keeps its value across passes,
documented in `docs/modules/kernel-live.md` with a test both compilers pass
(as recommended); the tools evaluate a selection once to a handle;
`check-tier.sh` classifies `Tests/*` before `*.md` and diffs with
`--no-renames`, a matrix gate fails when any step fails and `--bar` over no
rows exits 1; the `sudo ln` line quotes its paths, each checkout install
attempt has its own partial folder, the `kajo` target builds with strict
memory safety (one `unsafe`, an `fflush(stdout)`), `new-check.sh`'s
0-symbols check has a positive control and `dist.sh` asserts the frameworks'
compile flags; `ProtocolClient` bounds a line at 64 MiB and closes its
descriptor once, by whoever ends last; `PairingTokenStore.renew` answers a
token only when it was written whole and renamed into place and `load`
replaces a token file wider than 0600 or a link in its place (as
recommended); a reply's line is timed when it was read; `ShellBridge`'s four
signal sites root their Semaphore by a pending root the drain releases (the
report's path existed: a re-registration could free the Semaphore under a
queued signal and the drain signal whatever took its entry); a waiting
Process loaded from an image gets its wait send's length from the
instruction that ends at its saved pc, with no image format change; the
tests part 1 owed; `interpret` identical but for the jump table's page and
offset, `just arc-check` passing, the gate's aligned A/B against 18e274f
0.996 to 1.008 at 1 worker and 0.954 to 1.059 at 8 with instruction ratios
0.999 to 1.002; two gate runs stopped on this part's own faults (a new
test's senders on the global dispatch queue not run within 60 s under the
full sanitized suite, now threads of their own; `device-rows.sh` assigning
to `status`, read-only in zsh; and part 1's unpaired-connections test, whose
4000-send evaluate passed its 300 s under the sanitizer and twelve loops,
partly because code generation asked `inlinable:` again for every send of a
chain) and the third, `just check 18e274f` on 06e74a6, the core tier in 15
458 s, passed every gate (419 + 153 tests in every test gate,
ThreadSanitizer 0 reports alone and under load, 248 kernel tests headless
and on the iPhone, the four fuzzers with "libFuzzer build: ok" at 0.87 to
3.14 million runs, the Mac matrix's ring under `young=stw` 164 to 220 frames
behind 8 to 10 fallbacks and every other row 0, the iPhone 0 fallbacks and 1
and 2 frames in the same row); not done: the kernel fuzz mode compares
instance-side methods of one class only, a String that is not UTF-8 built by
a program still overflows the kernel compiler's stack, a `printOn:` that
asks an element for its `printString` passes `printOf:`'s guard by, the
reaper's 100 ms wake-up lasts as long as any request pends, the iPad; one
question answered by the owner on 2026-11-11 as recommended (the reaper's
reply does not name the VMError's kind, not now).
