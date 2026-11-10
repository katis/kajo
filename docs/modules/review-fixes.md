# The second review's fixes

The owner asked on 2026-11-10 for a thorough review of the whole implementation.
Five Opus reviewers read the tree at d78afcc in parallel, read-only, one area
each (the collectors; the interpreter, loader, workers and Processes; the
primitives, the shell surface and the development protocol; the compilers and
the kernel; the tools, app, shells, generator, CLI and scripts). Their reports
are `docs/reviews/2026-11-10/<area>.md`, 42 findings in all, each with the
invariant, the breaking path, the neighbours that keep it, a test and a fix
sketch. The main session confirmed the top ones in the code before this brief
(primitive 93, `zeroLongBytes`, the accept loop, `Connection.send` after
`close`, the `DevClient` resend list, the hosts' `Int64(d)`, `Transcript
show:`, the retry marker, `check-tier.sh`'s `*.md` rule and the matrix gate's
status). A finding is named below as `<area>.F<n>`.

This module fixes them in two parts, each one agent and one gate run: part 1
is everything critical or high plus the medium items in the same files (the
VM, the protocol transport, the kernel's exceptions, Transcript and
registries, the hosts' numbers, the client's resend list); part 2 is the
rest (the compilers' agreement, Tonel, the tools, the scripts, the lows).
Every fix comes with the test the report describes (one that fails on
d78afcc), or says why none can.

## Part 1 (this agent)

### Critical

1. **`primitives.F1` = `interpreter.F1`: primitive 93 un-protects verified
   code.** `ObjectModelPrimitives.swift` case 93 refuses only a receiver of a
   sealed class; a made method's bytecodes ByteArray and literal Array are
   read-only and pinned for good but not sealed, and `slotAt:` (117) reaches
   them from the Method. Fix: 93 refuses to clear the bit of an object pinned
   for good (`Header.isPinnedForGood`; a frame pin is not that), in every
   build. Check that nothing legitimate clears the bit on a pinned object
   (grep `pinForGood` callers: method parts, what else?) and that `beWritable`
   on an ordinary read-only object still works. Test: a kernel test and a
   Swift test that `(Object >> #printString) slotAt: k` then `beWritable`
   answers failure for the bytecodes and the literals and the method still
   runs; a `ReadOnlyTest` that an ordinary read-only Array can be made
   writable. Say in the doc whether any other path (97/98, `become:`,
   `forward`, reshape, primitive 38 into a read-only target, `instVarAt:put:`
   on a Method) can reach those parts: trace each.
2. **`collectors.F1`: `zeroLongBytes` polls without rechecking.**
   `LongBytes.swift:86-107`: after a `byteWorkPoll` that parked, re-read the
   object's body words and offset as `copyBytesPolled` does; if the length
   changed (a `become:` in a stop), stop zeroing (whatever the object became
   is already whole). Bound every `zeroBytes` chunk by the length read after
   the poll, with a real check, not an `assert`. And keep an object that is
   still being initialised out of the instance walks: either set the old-map
   bit after the fill (check every reader of the bit: the marker's snapshot,
   the sweeps, the instance walks, the verifier) or have `walkInstances` and
   `walkPointers` skip pending roots (`collectors.F4` is the same exposure for
   `fillFresh`'s partial Strings; choose one mechanism for both and write why).
   Test: a VM test with 2 workers under `collectAtEveryAllocation` or a stop
   stress where one Process allocates a long ByteArray while another runs
   `ByteArray allInstances` and `become:`s what it finds with a short
   ByteArray; it must trap on d78afcc (run it by hand there and record the
   trap in the doc, as the rules say a trapping variant is) and pass after.

### High

3. **`interpreter.F2`: `process.suspend` of a waiting Process.**
   `Debugging.swift` `interrupt(kind: debugStop)` on a waiting Process
   unlinks it from its Semaphore and makes it ready with
   `debugStopAfterSend`; proceeding returns from `wait` unsignalled. Fix so
   that a proceed re-enters the wait: the simplest sound shape is to leave the
   stop's pc at the `wait` send (as a poll's rewind does for a running
   Process) so proceeding re-executes the send and the Process waits again
   (or passes if the Semaphore has excess signals); say how the suspended
   primitive's operands are restored (`suspendAfterPrimitiveLocked`). Kind 1
   (terminate) keeps unlinking. Test: a Process in `aSemaphore critical:`
   suspended through the protocol and proceeded does not enter the critical
   section until the Semaphore is signalled.
4. **`primitives.F2`: the accept loop and unpaired connections.**
   `Server.swift` `acceptLoop` returns on any error but `EINTR`: on
   `EMFILE`, `ENFILE`, `ECONNABORTED`, `EAGAIN` it sleeps a bounded moment
   (10 to 100 ms) and continues; only a closed listener ends it. A
   connection that has not presented the token is bounded: at most 8 such
   at once (a new one closes the oldest unauthenticated), at most 4 KiB
   buffered before the token line and 5 s to present it; the limits are
   constants named in the doc. Test: 20 connections that send nothing are
   accepted and closed and a paired client still connects; a connection
   sending 1 MiB without a newline is closed.
5. **`primitives.F3`: a write enqueued after `close`.** `Server.swift`
   `Connection.send`/`close` and `ClientHost.swift` `ClientConnection`: the
   `queue.async` of the write happens under the same lock that reads
   `closed`, or the queued block re-checks `closed` under the lock before
   writing; the descriptor is closed once, after every write, and never
   under a write. Test: a stress of concurrent sends and a close with the
   assertion that no write happens after the close (count under the lock).
6. **`primitives.F4`: the image never hears `session.close` when the server
   ends a connection.** `replaceToken`, `dropConnections`, the 64 MiB
   backlog drop and `stop` set `closed` first and the reader never posts.
   Fix: every server-side end posts the session's close to the image once
   (the reader's path or the closer's, never both). Test: New token with an
   open session leaves no `DevSession` in `Smalltalk sessions` (or whatever
   the registry is).
7. **`kernel.F1`: `Transcript show:` inside the lock.** `displayString`,
   `printString` and the `nextPutAll:` of a non-String run outside
   `critical:`; inside it only the stream's `nextPutAll:` of a String and
   the contents read. Test: `Transcript show: anObjectWhoseDisplayStringFails`
   reports the error and a following `Transcript showLine:` still works.
8. **`kernel.F2`: the retry marker is `ExceptionSet`.** A private object
   nothing else answers (a class-side instance of a private class, or a
   unique `Object new` held in a class variable created at build). Test:
   `[ExceptionSet] on: Error do: [:e | nil]` answers `ExceptionSet`.
9. **`kernel.F3`: `Exception>>outer` leaves `handlerContext` on the outer
   handler**, and `kernel.F10` (`pass` with no outer handler returns from the
   inner `on:do:` instead of resuming at the signal for a resumable
   exception; `retryUsing:` runs its block inside the busy handler): fix the
   three against ANSI's semantics (Pharo's `Exception>>outer`, `pass` and
   `retryUsing:` are the reference, not to copy). Tests: the report's
   examples (`x * 10` runs after an outer `resume: 1`; `[Notification
   signal. #after] on: Notification do: [:e | e pass]` answers `#after`).
10. **`kernel.F4` and `kernel.F5`: unsynchronized registries.** `Smalltalk`'s
    sources, organizations, packages, definitions and undeclared tables, the
    Pragma index, `DevSession`'s handles and `nextHandle`, `DevProtocol`'s
    argument names: each gets the lock its neighbours have (the pending,
    sessions, stops, View registry and Delay tables are locked: use the same
    shape), and every rebuild (`Pragma rebuildIndex`, `rehashTo:`,
    `rebuildKinds`) builds in a temporary and publishes whole, as
    `rebuildClassNames` does since 211a6ee. Grep the kernel for every
    `:= IdentityDictionary new` / `:= Dictionary new` / `:= Array new:` on a
    class-side variable followed by a fill, and list them in the doc with
    what each became. Test: `handleOf:` from 8 Processes at once never
    answers the same handle twice; a class redefinition from 4 request
    Processes at once leaves `Pragma allNamed:` complete.
11. **`interpreter.F3`: test primitive 39 (`slowPeek:`)** is dispatched in
    every build and reads weak slots without `keepAliveRead`. Fix: either
    `keepAliveRead` on its read and the compiler refusing it outside the
    tests' build, or the primitive gone from the product build behind the
    same switch the other test-only paths use; say which and why.
12. **`tools.F1`: the hosts' `num()`.** `AppKitHost.swift:234` and
    `UIKitHost.swift:213`: `.int` only when `abs(d) < 2^53` (and the other
    `Int64(` of a Double in `KajoApp`, each checked), `.double` otherwise.
    Test: `ShellTests` sets a view's width to `1.0e20` and reads it back.
13. **`tools.F2`: the resend list.** `DevClient` (`tools/Client/DevClient.class.st:577`)
    holds back after a reconnect every request that changes a Process or
    removes code: `process.proceed`, `process.restart`, `process.retrySend`,
    `process.terminate`, `process.suspend`, `process.step`, `method.remove`,
    `class.remove`, beside the four it holds back today; a held-back request
    answers its block an error naming the dropped link (as `evaluate` does).
    Test in `tools/Tests/DevClientTest`.
14. **`kernel.F12`: `critical:` loses its lock when the Process is
    terminated between `wait` and `ensure:`.** The wait goes inside the
    `ensure:`'s receiver block with a flag that says whether it was acquired
    (Pharo's `Semaphore>>critical:` shape), for `Semaphore` and `Mutex`.
    Test: terminate a Process parked in `critical:`'s wait and assert the
    Semaphore still has its one signal.
15. **`kernel.F13`: a client can suspend or terminate the protocol Process
    itself.** `process.suspend`, `process.terminate`, `process.step` and
    `process.evaluate` on the protocol's own Process answer a refusal reply.

### Medium in the same files

16. `primitives.F5`: the JSON reader's duplicate-key check is quadratic:
    a Set of the keys per object (`JSON.swift:124`), on both sides.
17. `primitives.F6`: primitive 148's temporary file has a fixed name and
    the write is not serialized: a per-write unique name in the same
    directory (`mkstemp`-style, `O_CREAT | O_EXCL` kept, `O_NOFOLLOW`) and
    one `rename` over the target; two concurrent writes of one file leave
    one writer's whole text, never a mix.
18. `primitives.F7`'s second half: `ProjectWriter`'s remove never removes a
    directory and never recurses (a directory named `X.class.st` is a
    refusal); the first half (the image chooses the project directory) is
    the owner's, question 1 below: build nothing for it.
19. `primitives.F9`: primitives 154 and 160 dequeue before they allocate;
    allocate first (or put the item back on failure) so a heap-full
    failure loses nothing.
20. `primitives.F10`: a `ShellProcess` used after `release` is checked (the
    entry's generation or a released flag), a refusal, never a read of
    whatever reused the entry.
21. `collectors.F2`: primitive 38's pointer copy and the pointer
    `shallowCopy` over a large object poll between chunks as the byte
    versions do (the barriers per store stay); `collectors.F3`: the final
    mark's weak-slot pass is bounded or polled per 4096 slots like the
    marker's large-object scan, and the doc says what the bound is.
22. `kernel.F11`: `Fraction` and `Float` that are `=` hash alike
    (`Fraction>>hash` as the Float's when it has one, Pharo's rule).
23. `interpreter.F4`: primitive 156's frame-position assumption against a
    frame made by an interrupt: check it, refuse when the running frame is
    an interrupt's (`FrameMarker.discard`), test it.
24. `interpreter.F5`: a pending interrupt or terminate request is in the
    host record only; say in the doc what a save does with it today
    (refuse the save while one is pending, as `processesHaveFrames` refuses,
    is the cheapest sound answer) and build that.

### Bar

- Every fix above has its test, failing on d78afcc where a test can (say
  which cannot and why); the two critical ones also run by hand on d78afcc
  with the trap or the rewritten bytecodes recorded in the doc.
- `interpret` identical instruction for instruction (`just arc-check` and the
  disassembly diff against d78afcc); the aligned A/B within noise.
- Primitive 93's refusal, 148's new temporary name and 38's polls in
  `ExtremeIntegerTests` where they take an integer.
- The protocol fuzzer runs 120 s on the changed reader with "libFuzzer
  build: ok".
- `just check d78afcc` on the final code commit: the core tier (the VM
  changes), every gate; the Mac and iPhone matrices' `--bar` as before.
- The round trip (`scripts/canonical-tonel.sh --check`) clean on every
  kernel commit.

### Open questions for the owner (build the recommended option; list them)

1. `primitives.F7`: the image names the client's project directory in
   `ClientHost connect`, so Smalltalk code in a development image can make
   the host write and remove `.class.st` files in any directory the user can
   write. Recommended: the host decides (the Kajo app's product mode and
   `kajo run --project` already know the directory; the tools ask the host
   for it by a `project` op instead of passing one), a later follow-up with
   the owner's answer. Not built here.
2. `primitives.F2`'s limits (8 unauthenticated connections, 4 KiB, 5 s):
   recommended as named; say if the phone's pairing flow needs more.
3. `interpreter.F2`: a suspended waiting Process re-waits on proceed
   (recommended) against Pharo's behaviour of resuming it as signalled.

## Part 2 (the next agent; not this one)

`kernel.F6` (recursion bounds in `analyze:`/`gen:` and `printOf:`),
`kernel.F7` (identifiers above 127: the Smalltalk scanner follows the
bootstrap's rule), `kernel.F8` (a `[` in a pattern comment: the writer
escapes or refuses, both readers agree), `kernel.F9` (redefinition against
subclasses' class variables and ivar/class-variable clashes in `ClassRules`),
`kernel.F14` and `F15` (the Smalltalk generator refuses what the assembler
refuses; the `<primitive:>` range), `kernel.F16` (the Smalltalk compiler
fuzzed through the make primitive), `kernel.F17` (document), `tools.F3`
(evaluate the selection once), `tools.F4` and `F5` (`check-tier.sh`:
`--no-renames`, fixtures' `.md` owe the swift tier; the matrix gate's
status from every step), `tools.F6`, `primitives.F8`, the notes.

## As built (part 1)

Built 2026-11-10 on master from 8a8847d (the code d78afcc's), one finding
or one group per commit, every one named by its `<area>.F<n>`. The tests
live beside their neighbours or in `Tests/KajoVMTests/ReviewFixes/` and
`Tests/KajoCompilerTests/ReviewFixes{Kernel,Transport}Tests.swift`; each
was run on 8a8847d in a worktree (adapted only where the test needs an API
the fix adds; said per item) and the outputs are in the hand-back's
`failing-before.txt`.

### Critical

**1. `primitives.F1` = `interpreter.F1`: primitive 93** (18038c7). Case 93
refuses to clear the read-only bit of an object pinned for good (setting
it still works; a frame pin does not refuse). Every object the VM makes
read-only is now pinned for good: the method parts, literals and Symbols
were; class pools (the image build's `allocatePinned`, 145's and 146's
pools) and a method's Pragmas and their argument Arrays (`MethodBuilding`)
joined them. `grep pinForGood`: methods, bytecodes, literal frames,
literals (`readOnlyPinned`), Symbols (`intern`, primitive 135's interning),
classes and metaclasses (image build, 145), nil, true, false; nothing
legitimately clears the bit of any of them (no kernel caller of
`beWritable` but the test of an ordinary Array). Tests:
`ReadOnlyTests.primitive93NeverUnprotectsAMethodsParts` (the bytecodes,
the literal frame, another method's frame and a Symbol refuse; setting
works; the method runs; an ordinary read-only Array becomes writable) and
`ReadOnlyTest>>testAMethodsPartsStayReadOnly`. On 8a8847d the kernel test
fails ("Expected Error to be signaled"), and the hand run (a temporary
`HandRunTest` in the worktree: compile `victim ^ 7`, clear the bytecodes'
bit, write `push_temp 255; return_top`, run it) printed

    hand-run before: #[11 7 13] readOnly=true
    hand-run setReadOnly: false answered true
    hand-run after: #[0 255 13] readOnly=false
    hand-run literals setReadOnly: false answered true
    KajoVM/ObjectMemory.swift:208: Assertion failed      (exit 133)

The other paths to a method's parts, traced: 97 and 98 install or remove
a whole method the make primitive verified, they never write into one;
`become:` (primitive 8) refuses read-only objects on both sides and sealed
classes (`Machine.become`); `becomeForward` is not dispatched from
Smalltalk (primitive 9 is not in the table; only 146's own forwarding
uses it); a reshape refuses read-only instances (`ReshapeError.
readOnlyInstance`) and Array and ByteArray are kernel classes 146 does not
reshape into a method's parts anyway; primitive 38 refuses a read-only
receiver (pointers and bytes), 2 refuses read-only receivers and Strings
and Symbols, 128 refuses read-only; `instVarAt:put:` refuses a sealed
receiver (a Method) and stores through the read-only check; `slotAt:put:`
does not exist (the make primitive refuses it with `instVarAt:put:`,
`become:` and `becomeForward:` as literals of sealed extensions). None
reaches them now that 93 cannot clear the bit.

**2. `collectors.F1` and `F4`: the zeroing and the walks** (26dcf96).
One mechanism for both: a pending root carries a "building" mark
(`registerPending(…, building: true)`, `Machine.holdPending`, a byte table
`pendingBuilding` beside `pendingSlots` under `pendingLock`), and the walks
of 167 to 170 skip marked objects (`walkInstances` / `walkPointers`
`building:`, read in the stop). Chosen over setting the old-map bit after
the fill because the old map is read by the snapshot, both sweeps, the
verifiers and the walks, and an old entry without its bit is a state every
one of them would have to learn (the one-owner rule); a pending root is
already the object nothing else holds. Plain pending roots (Semaphores
waiting for host signals, the large-allocation trigger's root, the sweep
and marking waits' objects) are not marked and stay visible. And the
zeroing itself: `zeroLongBytes` re-reads its object's body words and
offset after a poll that parked and stops when either changed (counted
`zeroingCutOff`); `zeroBytes` checks used, bytes, large and the bound in
every build and answers false (it was an `assert`). Test switches
`buildingPauseUs` (a sleep between chunks, so a hunt lands inside) and
`walksSeeBuilding` (the broken variant). Tests (`ZeroingTests`): a hunter
Process running `ByteArray allInstances` and `become:`ing the first long
ByteArray it finds with an 8-byte one while another allocates one of
2^24 - 7 bytes: it finds it only whole, no cut-off; with the broken
variant it finds it mid-zeroing and the recheck stops the zeroing
(`zeroingCutOff >= 1`), the heap verifies. The same for a 1 MiB String
built by 123: no hunt sees a zero last byte, the broken variant does. On
8a8847d (the worktree given only the sleep switch) the first test traps:

    KajoVM/LongBytes.swift:172: Assertion failed      (signal 5)

### High

**3. `interpreter.F2`: suspending a waiting Process** (4769e88). The
Process record keeps the length of the `wait` send a Process suspended in
(`waitSendLength`, set by `waitSemaphore` under the scheduler lock); a
debug stop of a waiting Process rewinds its saved pc by it, so the stop is
the rewound kind (`stopForDebugger`, as a poll's) and proceeding sends
`wait` again. The argument for the operands: `wait` takes none, and
`suspendAfterPrimitiveLocked` wrote the primitive's result into the
receiver's slot, and 22's result is its receiver, the Semaphore: the stack
at the saved sp is exactly the send's operand at its start, the depth the
verifier traced there. A waiting Process loaded from an image has no
recorded length and stops after the send as before (not done). Terminate
keeps unlinking and unwinding from after the send. Test:
`DebuggerProtocolTests.aSuspendedWaiterWaitsAgainWhenProceeded` (a Process
in `critical:` behind a held mutex, suspended and proceeded through the
protocol, is waiting again and has not entered; a signal lets it in).

**4. `primitives.F2`: the accept loop** (7683253). Only a closed listener
ends the accept loop; any other `accept` failure is counted
(`acceptFailures`) and waited out, 10 ms doubling to 100 ms. A connection
that has not opened a session is bounded by `ProtocolServer.Limits`:
`unpairedConnections` 8 (a new one closes the oldest unpaired one),
`unpairedBytes` 4096 (newlines included, before its `session.open` line
ends), `unpairedNs` 5 s since it was accepted (the reader polls with the
remaining time); closes are counted (`unpairedClosed`). The session's own
lines keep the 16 MiB rule. Test:
`ReviewFixesTransportTests.connectionsWithoutASessionAreBounded` (20 idle
connections all closed, the first twelve by the cap and the last eight by
the time limit set to 2 s; 1 MiB with no newline closed; a paired client
served, with a line longer than 4 KiB). Limits of the fix: the `EMFILE`
path is not tested (lowering the descriptor limit of the test process
would starve the suite); the time and byte limits are per connection, so
a peer opening connections faster than 8 per 5 s churns the cap without
holding descriptors past it.

**5. `primitives.F3`: a write after close** (7683253). Server: `send`
enqueues its write under the lock that reads `closed`, `close` sets it and
enqueues the shutdown under it too, and the descriptor is closed once by
the connection's reader after its loop ends and the queue drained
(`Connection.finish`), so neither a queued write nor the reader's `read`
ever meets a reused number; a write block that meets the shutdown counts
`lateWrites` and writes nothing. Client (`ClientConnection`): writes
enqueued under the lock while `fd` is set, `drop` and `close` shut down
under it, `release` retires the descriptor under it and drains the queue
before closing. Test: `noWriteRunsAfterItsConnectionsClose` (eight
threads sending while a close comes, the old window held open by a sleep,
`lateWrites == 0` in 20 rounds). It cannot run on 8a8847d as it stands
(the counter is the fix's instrumentation); the client side has no test of
its own (the same shape).

**6. `primitives.F4`: session.close** (7683253). The reader posts
`session.close` whenever the session was opened (`wasOpened`), whoever
ended the connection; it is the only poster. `DevProtocol sessionCount`
reads the registry. Test: `aNewTokenTellsTheImageTheSessionEnded` (after
New token, and after `dropConnections`, the image holds only the new
session).

**7. `kernel.F1`: Transcript** (a0d9450). `show:` and `showLine:` make
their text with `textOf:` outside the lock (a String as it is, else its
`displayString`, which must answer a String); inside, only the String is
appended. Test: `TranscriptTest>>testAFailingDisplayStringLeavesThe
TranscriptUsable` (`TranscriptTestProbe`'s `printOn:` fails in a Process
that does not handle it; a following `showLine:` and a `showLine: 42` both
return within 30 s).

**8. `kernel.F2`: the retry marker** (10138db). `Exception
retryMarker` answers a private `Object new` held in Exception's class
variable `RetryMarker`, made by `Exception class>>initialize` at the image
build (and lazily in an image built without initialization). Test:
`ExceptionTest>>testRetryMarkerIsNoValueAProgramAnswers`.

**9. `kernel.F3` and `F10`: outer, pass, retryUsing:** (10138db). `outer`
saves `handlerContext`, searches through `outerSearch` (the frame a
resumption returns from), then restores it and sets the inner handler's
busy flag again; `outerContext` is cleared after the search. `pass` with
no enclosing handler resumes a resumable exception at its signal with the
default action's value (ANSI) and returns it from the `on:do:` otherwise.
`retryUsing:` puts its block in the `on:do:` frame's fifth temp and
returns the retry marker: `on:do:` unwinds and runs the block as its
protected block under the same handler. Tests: `testOuterLeavesTheInner
HandlerActive`, `testPassWithNoOuterHandlerResumesAResumableException`,
`testRetryUsingRunsTheBlockUnderTheSameHandler`. Deviation: the report's
first example (`[[x := Warning signal. x * 10] on: Warning do: [:e | e
outer + 1]] on: Warning do: [:e | e resume: 1]`) answers 2 under ANSI
(falling off the inner handler returns 2 from the inner `on:do:`), not 20
as the report wrote, and 2 on 8a8847d as well (from the outer one); the
test wraps it as `(…) * 100` to tell the two apart (200 now, 2 before) and
checks the report's 20 with `e resume: e outer + 1`.

**10. `kernel.F4` and `F5`: registries** (f25843a). One reentrant Mutex
`Smalltalk registry:` (made at the image build's first note) over
Smalltalk's sources, categories, packages, definitions and undeclared
Bindings, the pragma index and the Ephemeron registry; a Mutex per
DevSession for its handles; `DevProtocol critical:` (the protocol's lock)
for the argument names. Every rebuild fills a new table and publishes it
whole: `Pragma rebuildIndex` (under the registry lock, so no installation
in between is lost), `recordDefinitions:`, `replaceSources:`,
`HashedCollection>>rehashTo:`; `rebuildKinds` and `rebuildClassNames`
already did. Tests: `RegistryTest` (`handleOf:` from 8 Processes, 1600
distinct handles; 4 Processes compiling 40 methods each, every source
kept; the pragma index read 300 times while it is rebuilt 30 times).
Every class-side table filled in place, from the grep (class-side
variable assigned a new `IdentityDictionary`, `Dictionary`, `Set`,
`IdentitySet`, `OrderedCollection` or `Array` in a class-side method), and
what each became:

| Table | Where | Became |
|---|---|---|
| sources | `Smalltalk noteSource:of:`, `replaceSources:of:` | registry lock; replace builds the class's table first |
| organizations | `Smalltalk noteCategory:of:in:` | registry lock |
| packages | `Smalltalk notePackage:of:in:` | registry lock |
| definitions | `Smalltalk noteDefinition:of:`, `recordDefinitions:` | registry lock; recordDefinitions: builds then publishes |
| undeclared | `Smalltalk noteUndeclared:in:` | registry lock |
| classNames | `Smalltalk rebuildClassNames` | as 211a6ee built it (filled, then published) |
| PragmaIndex table | `Pragma rebuildIndex` | built in a temporary under the registry lock |
| argumentNames | `DevProtocol argumentNamesOf:` | the protocol's lock, parsed outside it |
| sessions, pending | `DevProtocol start` | made once at start; already under its lock |
| registry | `Ephemeron class>>registry` | registry lock around add and remove |
| stops, suspends | `Debugger class>>initialize` | made at the build; already under Debugger's lock |
| pending | `Delay class>>initialize` | made at the build; already locked |
| standing | `Unwinding class>>initialize` | made at the build; unchanged |
| registry | `View class>>initialize`, `resumeAfterSnapshot` | already under View's lock |
| timers, kindActions, frameActions | `UIEventLoop` | not changed: the event loop's main-affine state (UI code) |
| savedFrames, clients, debuggers, windows, connections, targetActions | `ToolWindow`, `DevTools`, `DevClient` (tools/) | not changed: the tools' UI Process only |

**11. `interpreter.F3`: primitive 39** (108a20b). Behind a VM test
switch, `VMTestSwitches.slowPeek` (the young-collection tests' runtime
sets it): every other VM's 39 fails at once. A runtime switch, like every
other test-only path here (`noBytePolls`, `walksSeeBuilding`, …), because
the tests and the product are the same build; there is no test-only build
to compile it out of. Without young collection its read goes through
`keepAliveRead`; with it the read is through an address held across a
blocking region on purpose (the epoch rule's test reads a reused eden in
its broken variant), which no barrier on the value can make sound. The
make primitive does not refuse 39 (with the switch off the primitive
fails and the method's own code runs). Test:
`testPrimitive39RunsOnlyWhenATestAsks` (both settings).

**12. `tools.F1`: the hosts' numbers** (e888d5a). `geometryValue` (one
function both hosts use, in `TextOffsets.swift`): a SmallInteger only for
a finite whole |d| < 2^53, a Double otherwise. The trace: the report's
path does not exist on AppKit, which keeps an NSView's frame within 2^45
(a width of 1.0e20 reads back 35 184 372 088 832, an integer, no trap),
but a non-finite value raised AppKit's exception at `set` (the test
process died on it, on 8a8847d as the before-run shows), and UIKit's
CALayer does the same; so every geometry argument of both hosts (x, y,
width, height, the frame and origin ops, the scroll position and the
divider) is finite or the call is refused (`geometryArgument`). The other
`Int64(` of a Double in `KajoApp`: none (the rest convert Ints and the
system's timestamps). Test: `aHugeGeometryReadsBackWithoutATrap` (AppKit
host; UIKit's path is the same function, built by `just apps`).

**13. `tools.F2`: the resend list** (95961a8). `DevClient class>>
notRetried` holds back `process.proceed`, `process.restart`,
`process.retrySend`, `process.terminate`, `process.suspend`,
`method.remove` and `class.remove` beside the four; each fails with the
error naming the dropped link. Test: `DevClientTest>>testADroppedLink
SendsNoCommandOrRemoveAgain`.

**14. `kernel.F12`: critical:** (e69525f). Semaphore and Mutex
`critical:` wait inside the `ensure:`'s protected block with `caught` set
right after the wait (Pharo's shape, the flag after the wait so a Process
the VM unlinks from its wait gives nothing back). That alone left one
window: a Process a signal released and asked to terminate before it ran
again took the terminate at its resume, before `caught := true`, and the
signal was lost. So the dequeue leaves such a terminate for the Process's
first poll (the record's `waitSendLength` says it was released from a
wait; the attention word and a countdown of 1 bring the poll at its next
send): `caught` is set first, with no send between. Deviation: a VM change
for a kernel item (in `dequeueLocked` and `runSlice`, not `interpret`).
Tests: `ReviewFixesKernelTests` driven slice by slice on one worker
(`CriticalProbe`): terminated while waiting, the Semaphore keeps its one
signal; released and terminated before it runs, the Semaphore and the
Mutex get theirs back. With the deferral switched off (by hand) the
second fails for both (excess 0).

**15. `kernel.F13`: the protocol Process** (da023f0). `DevSession>>
refuseServing:` answers an error for process.suspend, step, evaluate and
terminate of the protocol's own Process (`DevProtocol
isProtocolProcess:`). Test: `theProtocolProcessIsNotSuspendedOrTerminated`.

### Medium in the same files

16. `primitives.F5` (83310e2): the keys of an object in a `Set` in the one
JSON reader both sides use; `theDuplicateKeyCheckIsLinear` (100 000 keys
in a CPU budget). 17. `primitives.F6` (fd83f54): `writeTemporary(beside:)`,
`<path>.kajo-tmp-<16 hex digits>` per write, `O_CREAT | O_EXCL |
O_NOFOLLOW`, retried on `EEXIST`, never removing a name it did not create,
one `rename`; `twoWritersOfOneFileNeverTearIt`. 18. `primitives.F7`'s
second half (08d3495): a remove takes a regular file or a link (its own
type, not followed), a directory is a refusal; `aProjectRemoveNever
TakesADirectory`. 19. `primitives.F9` (e8bfa78): 154 and 160 put the item
back at the queue's head and signal for it again when they cannot
allocate (`ShellBridge.putBack`, `putBackRequest`;
`failAllocations` the tests' full heap); `aRequestTheImageCannotAllocate
IsNotLost` (154's path is the same shape, not tested on its own). 20.
`primitives.F10` (4db9370): `ShellVM` keeps the Processes it holds by id;
state, result, failure, wait, terminate and release of a released one are
refusals; `aReleasedShellProcessIsRefused`. 21. `collectors.F2` and `F3`
(c4fe338): 38's pointer copy and a large pointer object's `shallowCopy`
poll every `PointerWork.chunk` (32 768 slots, 256 KiB of words), 38 with
its hazard slots released for the poll and re-acquired, the copy a marked
pending root, a count changed by a stop a failure;
`thePointerCopiesPollBetweenChunks` (2^20 slots, longest stretch one
chunk). The final mark's weak pass is not bounded: it runs past the
commit point in the stop, which cannot poll, and moving it out of the
stop needs a read barrier that hides an unmarked referent from a weak read
until the pass has nilled it (a store-barrier-level change, outside this
part). Measured instead (`theWeakPassIsMeasuredPerSlot`, a WeakArray
of 2^20 slots each naming one live Array): 11.6 ms in the record's
`weakNs`, 11.1 ns a slot, in a debug build on the mini (a release build
not measured). The bound is therefore the weak holders' slot count times
that cost: a WeakArray of 16 777 215 slots adds about 186 ms (debug) to
every final mark; nothing in the kernel or the tools keeps a weak holder
of more than a few thousand slots.
22. `kernel.F11` (62cff96): `Fraction>>hash` is its `asFloat`'s (Fraction
and Float compare as Floats here, so that is the one consistent rule);
`FractionTest>>testAFractionHashesAsTheFloatItEquals`. 23. `interpreter.
F4` (428eb6b): `resend` refuses a frame with the discard or cascade marker
and checks R's fp against the verifier's traced depth at the send's start
(`rfp == sh + Frame.context + depth - n + 1`, the loader's rule), which
also catches a marked frame `terminateTo:` moved into place (it drops the
marker); `aResendFromAnInterruptsFrameIsRefused` (a waiting Process
interrupted for the debugger, whose `stopForDebugger` resends its
caller's send: refused, the Process waits again with its sp unchanged;
with both checks off by hand it resends and the saved sp grows by one).
24. `interpreter.F5` (bfed643): today a save drops a pending interrupt or
terminate request (they are in the host's record only, and `saveInStop`
wrote none of it); now the save is refused while any record has one
(`snapshotsRefusedPending`); `aSaveWaitsForPendingInterrupts`.

### The bar

- **Tests failing before.** Every new test was run on 8a8847d in a worktree
  (`failing-before.txt` of the hand-back). Failing there: items 1 (both
  tests, and the hand run above), 2 (the trap above), 3, 4, 6, 7 (killed by
  its 300 s bound, the reporting Process deadlocked at 0 % CPU), 8, 9 (the
  outer and pass tests), 10 (handles and the pragma index), 11, 12 (the
  test process died at `set height: inf`), 13, 14 (the released-then-
  terminated case, for the Semaphore and the Mutex), 15, 16 (422 s against
  0.14 s), 17, 18, 20, 21 (polls 0, the stretch the whole copy), 22, 23,
  24. Passing there, honestly: item 9's `retryUsing:` test, item 10's
  concurrent compiles (no entry lost in that run; the lock is by
  construction) and item 14's "terminated while waiting" (the old shape
  already gave nothing back there; the failing case is the signalled one).
  Not runnable there, being the fix's own instrumentation: item 5's
  `lateWrites` and item 19's `failAllocations`; the broken variants of item
  2 (`walksSeeBuilding`) and the by-hand switch-offs of items 14 and 23 stand
  for them.
- **`interpret`.** Identical instruction for instruction: the two aligned
  `-enable-testing` release builds of the A/B (8a8847d and 4598647), 1817
  lines each, differ after normalizing addresses to the function's start
  only in the low bits of the jump table's address (`add x26, x26, #0x74e`
  against `#0xb4e`, four places, the table's page offset). `just arc-check`
  passes on 4598647 ("OK: no retain or release on the checked paths; the
  dispatch loop is one jump table"; `dequeueLocked` 120 instructions,
  `waitSemaphore` 374, ARC 0).
- **The aligned A/B** against 8a8847d (`scripts/ab.sh`, 5 interleaved
  runs, checksums the same everywhere): 1 worker 0.997 to 1.006, 8 workers
  0.977 to 1.031 with overlapping ranges, cycle ratios 0.997 to 1.012,
  instruction ratios 0.999 to 1.001.

| kernel | 1 worker | 8 workers |
|---|--:|--:|
| alloc | 1.006 | 1.002 |
| arith | 1.001 | 1.023 |
| fib | 0.997 | 0.977 |
| ivars | 0.998 | 1.010 |
| sends | 1.001 | 1.006 |
| st-closures | 0.999 | 1.031 |
| st-ivars | 1.001 | 1.017 |
| st-sends | 0.997 | 0.993 |
| storeheavy | 0.997 | 1.010 |

- **`ExtremeIntegerTests`** gained primitive 38 over a 40 000-slot Array
  (past one polled chunk), 93 with an integer argument and 148 with
  integers for its path and text; the suite passes (93 and 148 take no
  integer as such: an integer is refused like any other non-Boolean,
  non-String argument).
- **The protocol fuzzer** on the changed reader: `just fuzz protocol 120`,
  "libFuzzer build: ok (Apple Swift version 6.4.2)", 360 063 runs in 121 s,
  no crash.
- **The round trip** (`scripts/canonical-tonel.sh --check`) clean before
  every kernel or tools commit (each was rewritten by the script first, then
  checked) and on 4598647.
- **`just check 8a8847d`** on the final code commit: below.

### Deviations

- Item 14 needed a VM change (a terminate after a completed wait is left
  for the Process's first poll), in `dequeueLocked` and `runSlice`.
- Item 9: the report's first example answers 2 under ANSI, not 20; the
  test separates the old and new behaviour with `* 100`.
- Item 12: the report's trap is not reachable through an NSView (frames
  are clamped to 2^45); the real trap was a non-finite value at `set`,
  fixed by refusing non-finite geometry.
- Item 21's weak pass is measured, not bounded.
- Item 23 checks the traced depth as well as the marker: `terminateTo:`
  drops a moved frame's marker, so the marker rule alone misses the
  restart path.

### Not done

- The `EMFILE` accept path has no test (item 4); the client side of item 5
  has no test of its own; 154's put-back is tested only through 160's.
- A waiting Process loaded from an image has no recorded wait length; its
  debug stop is after the send as before (item 3).
- The UIEventLoop's timers and actions and the tools' class-side tables
  stay unsynchronized (main-affine UI state, item 10's table).
- The final mark's weak pass in a release build is not measured.
- The kernel report's further suggestion for item 7 (make the lock a Mutex):
  not done; the text is made outside the lock, which closes both the error
  and the nested-write deadlock.

### Open questions (decisions only)

1. `primitives.F7`: the host decides the client's project directory (the
   tools ask the host by a `project` op), a later follow-up; nothing built.
   Answered by the owner on 2026-11-10, as recommended.
2. `primitives.F2`'s limits: 8 unpaired connections, 4 KiB and 5 s before
   the session opens, as named; the phone's pairing flow sends one
   `session.open` line of about 100 bytes within a second, well inside
   them. Answered by the owner on 2026-11-10, as recommended.
3. `interpreter.F2`: a suspended waiting Process re-waits on proceed (its pc
   rewound to the wait send, the operand the Semaphore already in place);
   terminate keeps unlinking. Answered by the owner on 2026-11-10, as
   recommended.
4. New: should the final mark's weak pass leave the stop (a read barrier on
   weak slots that answers nil for an unmarked referent until the pass has
   run, with the sweep waiting for it)? Recommended: not now; the measured
   cost is proportional to weak slots, which no kernel table approaches.
