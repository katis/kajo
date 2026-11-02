# Model check: handshakes, epochs and entry ownership of young collection without stopping the world

Status: brief (2026-11-02). Becomes the description of the model as built.
`docs/VERIFICATION.md` layer 6: done before module 7 (young collection
without stopping the world) is written, kept beside the module and updated
when the protocol changes. Builds on the relocation model
(`docs/models/relocation.md`, `models/Sources/RelocationModel/`): reuse its
memory model, explorer and conventions; add a second library and test target
in the same `models/` package rather than a second package.

## What is modelled

ADR 0008's protocol as specified in `experiments/concurrent-young/SPEC.md`
("Handshakes", "Part 1: local collection", "Ordering and soundness", and the
amendments 7, 10, 14, 16 and 17), which module 7 will implement. The claims:

1. **No lost object.** Every object of the collected nursery that any
   mutator can reach after the collection ends was marked (copied) by it.
   The abstraction: a collection is a concurrent mark of the young set whose
   action on a marked object is the copy; the model needs marks, not bodies.
2. **The barrier-on round is necessary.** With a single round (stacks scanned
   in the same round that turns the barrier on) the model must find the
   SPEC's point 4 interleaving: worker B loads the flag as off, C opens the
   round, A acknowledges and is scanned, A loads X from old object G, B
   overwrites G's slot without a record, drops X, is scanned; X is lost.
   This is the AGENTS.md lesson "a single round is unsound even under
   sequential consistency"; the model must reproduce it under sequential
   consistency, so the memory-model relaxations are not what makes it fail.
3. **Termination is sound.** Stopping after the first drain round that
   copied nothing loses nothing: every unmarked reachable object at that
   point would have been found by a record published in that round.
4. **No premature reuse.** The old eden (and survivor-from) is reused only
   after every participant's epoch word passed the collection's epoch;
   blocking regions keep their epoch; waiting workers are quiescent
   (amendment 14) and that does not reopen a window.
5. **Exactly one owner per entry state.** A dead remembered holder whose
   free is deferred (amendment 10) is neither young nor old until its
   nursery's next collection: the old-space snapshot excludes it, the
   stop-the-world sweep leaves it used, and only its nursery's next
   collection frees it. The model has an abstract old-space collector that
   takes a snapshot and sweeps, and must show that with the deferred entry
   treated as old (the amendment-17 bug) the entry is freed twice or a new
   object in it is swept, and with the rule it is freed exactly once.
6. **Remembered-set re-arm.** A holder removed by the collector's
   fetch-and-clear before a concurrent store is either pushed again by the
   storer or its store is seen by the collector's later scan (SPEC point 2);
   with the storer's load of the remembered word weakened to relaxed, show
   the loss.
7. **The owner's new eden half (offload, amendment 7).** An object the owner
   allocates after the flip and before the snapshot can hold the only
   reference to a collected object; without the new-half scan at T1 and the
   snoop, show the loss; with both, no loss.

The negative claims must be shown: single round (claim 2), no termination
rule or terminating at the first round that found nothing new rather than
copied nothing (claim 3, if the model can distinguish them; otherwise say
so), epoch rule off (claim 4), deferred entry treated as old (claim 5),
relaxed remembered-word load (claim 6), new-half scan and snoop off (claim
7). The model is believed only when each of these finds its trace.

## How

As the relocation model: an exhaustive explorer over small configurations,
breadth-first so traces are shortest, with switches on by default and one
negative test per switch. Keep the model about marks and edges, not bodies:

- **Threads**: one collector C (the owner itself in `local`, a separate
  thread in `offload`; one configuration each), two mutators, one abstract
  old-space collector that can take a snapshot and sweep at a step (for
  claim 5), one stopper for stop-the-world (so "stops and collections are
  not interleaved" is part of the state).
- **Objects**: three or four, each old or young-in-nursery-k, with one or
  two slots; a per-object marked flag; a remembered word per holder with
  the membership bit and the pending bit of amendment 9; a deferred-free
  state per entry.
- **Mutator steps**: load a slot into a register (the register is the
  stack root), store a register into a slot (with the insertion barrier,
  and the deletion barrier when the flag word says collecting), drop a
  register, poll (acknowledge open rounds: scan stack at H1, publish
  buffers at H1 and later rounds; advance the epoch word), enter and leave a
  blocking region, leave and enter the VM, allocate in the new half after
  the flip (offload).
- **Collector steps**: open H0; open H1; T1 (scan parked roots, the
  remembered set with fetch-and-clear, the published records); drain
  rounds; finish (flag off, sweep the young log, defer frees of dead
  remembered holders, bump the epoch); wait for the epoch before reuse;
  free deferred entries at the next collection.
- **Memory model**: the relocation model's. Claim 2 must fail even with the
  store buffers disabled (a configuration switch `sequentiallyConsistent`),
  so that its cause is shown to be the protocol and not the memory model.
- **Search and reporting**: as the relocation model, with state counts,
  longest traces and times per configuration recorded in this document, and
  each negative trace copied as a comment above its test.

## Done when

- `cd models && swift test` still passes within about a minute in debug on
  the M2 Max, now including the young-collection suites: the seven claims
  hold with every switch on, and each negative test finds its violation and
  prints the trace.
- The memory-model abstraction is the shared one; any extension it needed
  is written down in both documents.
- The steps are mapped to the SPEC sections, to the experiment's function
  names in `experiments/concurrent-young/swift/Sources/VMR/` and to the
  names module 7 will use, in a table in this document.
- Anything the model finds questionable in the protocol is listed first in
  the hand-back and in this document, with a trace or with the reasoning
  marked as such.
