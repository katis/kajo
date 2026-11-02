# Model check: the entry state machine of concurrent relocation

Status: brief (2026-11-02). Becomes the description of the model as built.
`docs/VERIFICATION.md` layer 6: done before module 6 (concurrent relocation)
is written, kept beside the module and updated when the protocol changes.

## What is modelled

ADR 0007's copy protocol as specified in
`experiments/concurrent-relocation/SPEC.md` Part 2 ("Entry state encoding",
"Copy protocol", "Pins and hazards", "Freeing old blocks: epochs"), which
module 6 will implement over module 1's entries. The claims to check:

1. **No lost store.** A mutator store into a slot of an object that is being
   relocated is visible in the body the entry leads to after the switch,
   whatever the interleaving. The post-store check (relaxed load of the
   offset, seq_cst store of the slot, seq_cst reload of the offset, redo in
   the slow path while RELOCATING or changed) is what makes this hold.
2. **No stale read.** A mutator read after the switch reads the new body,
   and a read during RELOCATING reads the intact old body; no read ever
   sees uninitialised to-space.
3. **No hazarded move.** An object under a worker's hazard slot is never
   switched while the hazard is held: either the relocator sees the hazard
   after its CAS and reverts, or the primitive sees RELOCATING and waits for
   the revert or the switch before using a body pointer.
4. **No premature free.** A block is freed by the epoch rule only when no
   worker can still hold a body pointer into it: every worker has passed a
   poll, a park, or left the VM since the switch.
5. **No RELOCATING at a pause.** When the world is stopped no entry is in
   the RELOCATING state.

The negative claims must be shown too: with the post-store check removed
claim 1 fails; with the hazard check removed claim 3 fails; with the epoch
rule removed claim 4 fails; with the seq_cst on the store and reload
weakened to release/acquire claim 1 fails under the memory model used
(the AGENTS.md lesson: release/acquire lets them reorder). The model is only
believed when it finds each of these.

## How

An exhaustive interleaving explorer written in Swift, in its own SwiftPM
package at `models/` so that it does not slow the VM's build, with a test
target that runs the checks (`swift test` inside `models/`). TLA+ is the
usual tool; the explorer is chosen so the model runs in the same toolchain
as the VM, in CI, with no Java. Keep the model small and explicit:

- **Threads**: one relocator, two mutators (a third as a configuration to
  show the state space is still finite), one stopper that can request a
  pause at any step.
- **Objects**: two or three entries, each with an offset word (NORMAL,
  RELOCATING, switched) and two bodies (old, new) of one or two slots each;
  one block holding the old bodies.
- **Mutator steps**: load offset; store slot (seq_cst) through the loaded
  offset; reload offset (seq_cst); slow path (spin while RELOCATING, redo);
  read slot; take a hazard, use a body pointer across two accesses, release
  the hazard; poll (advance epoch word); park at a pause; leave and enter
  the VM.
- **Relocator steps**: CAS to RELOCATING; fence; read every hazard word;
  revert or copy slot by slot; switch; record the block pending with the
  epoch; increment the epoch; free the block when every worker's epoch word
  is past it; poll for a pause between objects.
- **Memory model**: model seq_cst operations as a single total order with
  the store buffer effects that matter for the claims, enough to make the
  release/acquire variant fail; document exactly which reorderings the model
  allows (an explicit per-thread store buffer for relaxed and release stores
  that drains at seq_cst operations is the recommended abstraction). State
  the limits plainly: this is not a full ARMv8 model.
- **Search**: depth-first over all interleavings with state hashing to prune
  revisits; report the number of states and the longest trace. A failing
  claim prints the interleaving as a numbered list of steps so a human can
  read it into a test.
- **Switches**: `postStoreCheck`, `hazardCheck`, `epochRule`,
  `seqCstStoreReload`, each on by default and each turned off by one test
  that expects the corresponding claim to fail.

## Done when

- `cd models && swift test` passes: the five claims hold with every switch
  on, and each of the four negative tests finds a violation and prints the
  trace, within a minute in debug on the M2 Max.
- State counts and the longest trace per configuration are recorded in this
  document, with the memory-model abstraction and its limits written down.
- The model's steps are mapped, in a table in this document, to the SPEC
  sections and to the names module 6 will use (`relocate`, `postStoreSlow`,
  `hazard`, `epoch`), so module 6's brief can require that any change to the
  protocol updates the model in the same commit.
- Each violation trace found by a negative test is written as a comment
  above that test, so the traces are readable without running anything.
