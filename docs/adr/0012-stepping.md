# ADR 0012: Stepping at the poll, stops as interrupts

Date: 2026-11-04
Status: proposed (module 9b, `docs/modules/development-protocol.md`)

## Context

The owner asked for stepping (into, over, out) in the first debugger. The
interpreter's fast loop is one jump table with a fixed register budget
(AGENTS.md: one extra call site cost 20 percent through register
pressure), and `just arc-check` and the bench A/B guard it: stepping must
add nothing to the dispatch loop, the send path or the return path. The
brief named two acceptable designs: a stepping copy of the method, or
running the stepped Process on a slow interpreter loop entered from the
poll.

## Decision

- **The step is a rule evaluated at the existing poll, and the stepped
  Process's countdown is kept at 1.** Every send and backward jump already
  counts the countdown down and takes the poll's slow path at zero
  (`pollSlow`, out of line). A stepped Process (its record's step mode,
  set by primitive 158 from the debugger, in the stopped Process itself)
  has its countdown set to 1 when it is resumed and after every poll, so
  every send and backward jump of that Process, and of no other, reaches
  `stepPoll`, which decides by the mode and the frame being stepped (its
  header index): into stops at the next poll after the stopped send ran
  again; over stops at the next poll in that frame or below it; out at the
  next poll below it.
- **Returns are caught by a return marker.** Primitive 158 marks the
  stepped frame with a new return marker (`FrameMarker.step`, beside 8a's
  discard and cascade) in its context word or its Context's marker slot;
  a marked frame's return already takes the out-of-line return path
  (`returnSlow`), which stops the Process in the caller after the send
  when its record still steps that frame. A stale marker is ignored.
- **A stop is an interrupt.** Stopping does not run Smalltalk from the
  poll: the Process is requeued with an interrupt in its record (taken
  under the scheduler lock by the worker that dequeues it), and when it is
  resumed the VM sends it `stopForDebugger` (at a send, its pc rewound to
  the send) or `stopForDebuggerAfterSend` (after a return) from where it
  stands, with the discard marker, so whatever that answers is dropped and
  the Process goes on as it was. The same mechanism makes another Process
  run `terminateUnwinding` (Process>>terminate runs ensure blocks) and a
  running or waiting Process stop on request (`process.suspend`).

## The alternatives

- **A stepping copy of the method** (bytecodes rewritten with a trap at
  every send and return, installed for the stepped frame only): rejected.
  It needs a second bytecode verifier pass over generated code, a copy per
  frame on the stack (every caller's frame names its method by its header
  word), the copy forwarded back on step-out, and the read-only and
  pinned-for-good rules of 8d for every copy; and a step into a callee
  needs its copy before the callee is activated, which the send path
  cannot do without a check.
- **A slow interpreter loop for the stepped Process** (a second `interpret`
  with a hook per instruction, entered from the poll): rejected for now.
  It is a second copy of the dispatch loop to keep in agreement with the
  first (every v1 fast path), for a gain this design does not need: the
  poll already sees every send and backward jump, which is the granularity
  of Pharo's step (a statement or a send); stepping per bytecode is not
  asked for. It remains the design if per-instruction stepping is ever
  wanted.

## Consequences

- The interpreter is unchanged: `interpret` is 1056 instructions with one
  jump table, as before, and the bench A/B is within noise
  (`docs/modules/development-protocol.md`, Measurements). `pollSlow` gains
  one record read for the running Process when it reaches its budget
  check, and `runSlice` one when it resumes a Process.
- A stepped Process runs every send through the poll's slow path while it
  steps: stepping over a send of 400 000 sends took about twice as long as
  running it (9.7 against 4.9 ms).
- Special sends whose fast path applies (`+` on SmallIntegers, `at:` on an
  Array) do not poll and are not stopping points, and an operand pushed
  before the stop is not re-read: assigning a variable in a frame stopped
  at a send changes its later uses, not the pending send's operand.
