# From experiments to a production VM: verification strategy

Status: agreed direction, 2026-11-02. Not yet started; the experiments are
still running. Revise as the production core takes shape.

## What the experiments are and are not

`experiments/` produces evidence, not code. Each experiment leaves behind a
SPEC.md (the protocol as built), a RESULTS.md (what it cost and where it
broke), tests that fail when a rule is switched off, verifiers that redo the
collector's work from scratch, and an ADR. Those are the assets.

The experiment code is a lineage of copies grown fast, with diagnostic
switches, benchmark plumbing and two of everything where a comparison was
needed. It is the reference implementation for the production core, not the
production core. `Sources/KajoVM` is written once, module by module, porting
each experiment's tests first and reading its code second. Where an
experiment found a credible alternative (a cheaper store check, a different
nursery layout, a different entry encoding), the production module hides
that decision behind a small interface so the alternative stays swappable.

## Why unit tests and ThreadSanitizer are not enough

A concurrent moving collector fails in ways that tests pass through: the
race needs a collection to land between two specific instructions, and a
natural collection rate lands there once a week. ThreadSanitizer reports
data races, not protocol races; it accepts a lost store if every access was
atomic, and it cannot see that two mappings of the heap alias (ADR 0007).
The experiments found their worst bugs by reasoning (the release/acquire
pair that reorders) or by a verifier (the snapshot that loses objects), not
by a test going red on its own.

## The layers, in the order they are built

1. **Checked build.** A build configuration in which every verifier runs at
   every pause: from-scratch reachability against the collector's result,
   entry and block invariants, relocation state, nursery ownership, mark
   sets. It is the default for development and runs in CI. The experiments'
   verifiers only ran in tests and selected scenarios; in production they
   are one flag away in every session.

2. **Stop-the-world as the oracle.** The stop-the-world collector stays in
   the codebase as a configuration, not as history. Every concurrent
   mechanism is checked by running the same program under both and
   comparing checksums and heap shape. Deleting the simple collector once
   the concurrent one works would delete the oracle.

3. **Stress modes.** Flags that make the collector run far more often than
   it would: collect at every allocation, collect every Nth bytecode,
   relocate every live block in every cycle, handshake at every poll,
   shrink nurseries to a few KiB. Every test and every randomized run can
   be executed under them.

4. **Randomized programs.** A generator that emits random bytecode programs
   doing allocate, store, load, drop, exchange between workers and process
   switches, with a checksum of the final heap. Each seed runs under the
   concurrent configuration and under the oracle, in stress modes, in the
   checked build. Thousands of seeds nightly; a failing seed becomes a
   committed regression test.

5. **Schedule perturbation.** Injected delays and yields at safepoint
   polls, in barrier slow paths, and between the steps of the copy protocol
   (after the CAS to RELOCATING, before the publish), enabled by a flag and
   driven by a seed. Swift has no deterministic scheduler we can run the VM
   under; widening the windows on purpose is the substitute. Runs with the
   randomized programs.

6. **A model of the protocols.** The entry state machine, the post-store
   check, the SATB predicates, the handshake and epoch freeing are small
   enough to write down in TLA+ (or an exhaustive interleaving explorer
   over two or three threads and a handful of objects) and check for lost
   objects and lost stores. This is done before the production relocation
   and young-collection modules are written, with the model kept beside
   the module and updated when the protocol changes.

7. **Input fuzzing.** The image loader and the bytecode or kasm loader read
   untrusted bytes. libFuzzer builds of those entry points
   (`-sanitize=fuzzer`), run in CI with a corpus. Strict memory safety in
   `KajoVM` keeps the unsafe surface greppable for the audit that fuzzing
   does not replace.

8. **Counters as telemetry.** Fallbacks to stop-the-world, redone stores,
   spins, hazard skips, handshake latency, eden-reuse waits, verifier
   outcomes. Reported in every benchmark, shown in the developer UI,
   collected from beta builds. The rule from AGENTS.md stands: a fallback is
   a provisioning failure to count and report, never to hide. In checked
   builds an invariant violation stops the VM with a report; in release
   builds it is recorded and the collector falls back to stop-the-world.
   Since the allocation stalls (docs/modules/allocation-stalls.md) a
   background worker's fallback must be justified by a completed cycle (or
   a full heap) and any other counts as `unjustifiedFallbacks`, a verifier
   failure in checked builds; the stalls themselves are telemetry.

9. **Device runs.** Nothing has run on an iPhone yet. The double mapping,
   collector thread QoS on asymmetric cores, memory under jetsam and the
   entry table's footprint are all open. ADR 0003 waits on that
   measurement. The scenario app gets an iOS target early, and the
   headless matrix runs on device as part of each collector milestone.

10. **Smalltalk-level tests.** Once the kernel exists, building the image is
    itself a test, kernel classes carry SUnit-style tests, and snapshot,
    load and verify is a round trip run in CI.

## The gate

Experiments: tests green, ThreadSanitizer clean, checksums equal to
stop-the-world, verifier clean in at least one scenario per benchmark.

Production, before any Smalltalk code runs on the core: all of the above,
plus the checked build in CI, the stress modes exercised by the test suite,
and the randomized-program oracle comparison running nightly. Fuzzing joins
when the loaders exist; the model check precedes the relocation and young
collection modules.

AOT 1 (2026-11-11, `docs/modules/aot.md`): every layer above now runs in both engines. The random programs run under the native engine in every configuration and resume across engines both ways, the whole VM suite runs natively under `KAJO_NATIVE_HARNESS=1 KAJO_NATIVE_RUNTIME=1`, ThreadSanitizer runs the native suites with the generated C compiled `-fsanitize=thread`, and broken variants of the generator are test switches (`AOTOptions.broken*`).
