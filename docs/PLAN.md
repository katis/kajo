# Build plan: from the experiments to `Sources/KajoVM`

Status: started 2026-11-02; modules 1 to 4 built the same day, modules 5 and 6 the next; the relocation and young-collection
models (`docs/models/`) are checked. A step or two at a time; the order below is the
current best guess, revised as modules land. `docs/VERIFICATION.md` says how
each module is verified; this file says what is built and in what order.

## Rules for every production module

- Written once, in `Sources/KajoVM/<Module>/`, one target for now (ADR 0002's
  open question is answered "later": split when a boundary has proven
  itself). Internal access across modules; `public` only on the VM's
  surface.
- **Tests first, code second.** Port the experiment's tests for the module
  before reading its code. Every rule the experiments found by a failing
  test keeps that test. Each module brief lists which tests it ports and
  which wait for a later module.
- **Strict memory safety is on** (`.strictMemorySafety()` in Package.swift).
  Every unsafe construct is written with `unsafe`; the experiments never did
  this. Keep the unsafe surface inside the object memory, collector and
  interpreter and make it greppable.
- **Checked build from day one.** Debug builds run every verifier at every
  pause and every invariant check; release builds keep them one runtime flag
  away. Stress flags (collect at every allocation, tiny spaces) exist from
  the first module.
- **Stop-the-world stays as the oracle.** The simple collector is a
  configuration, never deleted.
- **Counters, not logs.** Every fallback, retry and wait is a counter the
  tests and benchmarks read.
- **Hot-path rules** from AGENTS.md apply: no ARC, no existentials, one
  out-of-line slow call, `&+` arithmetic, structs in raw memory, 128-byte
  padded per-worker state. Check the arm64 assembly when touching dispatch.
- **Idle threads wait untimed.** No periodic wakeups anywhere in the VM
  (experiments/power).
- `just ios-check` passes after every module; `mach_vm.h` is never used.
- Each module ends with: its tests green, under load, under ThreadSanitizer;
  `docs/modules/<module>.md` updated from brief to description; AGENTS.md's
  project structure updated.

## Module order

| # | Module | Ports from | Gate before it |
|---|---|---|---|
| 1 | **Object memory** (built 2026-11-02, `docs/modules/object-memory.md`): oops and tags, header word, entry table, block heap, allocation, stop-the-world mark, sweep and compaction, become and bulk forward, reshape and instance enumeration, snapshot save and load, verifiers, counters | object-representation (B), concurrent-young's final layout (SPEC "Header word") | this plan |
| 2 | **Interpreter and loader** (built 2026-11-02, `docs/modules/interpreter.md`): bytecode set v0 (the experiments' set, behind the module; a real set is an open ADR), method and context representation, sends, primitives boundary, the kasm loader as the first loader | vm-language-bench, object-representation | module 1; the loader gets a fuzz target |
| 3 | **Workers, safepoints, Processes, scheduler** (built 2026-11-02, `docs/modules/workers.md`): OS-thread workers, safepoint protocol, Process-owned stacks, the main-affine ready queue and budgeted preemption of ADR 0004 | ui-thread-scheduling, concurrent-young's Process.swift | module 2; randomized programs start here |
| 4 | **Nursery** (built 2026-11-02, `docs/modules/nursery.md`): per-worker eden and survivors, age field, remembered sets, write barrier, stop-the-world scavenge (ADR 0005, 0007 age) | generational-gc, concurrent-relocation | module 3 |
| 5 | **Concurrent marking and lazy sweep** (built 2026-11-03, `docs/modules/concurrent-marking.md`; ADR 0006), marker at utility on device | concurrent-marking | module 4; schedule perturbation in place |
| 6 | **Concurrent relocation** through the entry switch (built 2026-11-03, `docs/modules/relocation.md`; ADR 0007) | concurrent-relocation | model check of the entry state machine and post-store check (done: `docs/models/relocation.md`) |
| 7 | **Young collection without stopping the world** (ADR 0008), mixed QoS policy | concurrent-young, power | model check of the handshake and epoch freeing (done: `docs/models/young-collection.md`) |
| 8 | **Kernel, compiler, image build**: Smalltalk sources under `kernel/`, a compiler in Smalltalk bootstrapped from a Swift one or from kasm, the first image | nothing yet; the bytecode-set ADR precedes it | module 3 at least |
| 9 | **Shells and development protocol**: macOS and iOS apps, remote development | ui-thread-scheduling's kajo-ui, device-measurement app | module 8 |

Modules 1 to 3 give a VM that runs kasm programs on many workers with a
stop-the-world collector and a frame-budgeted main thread. That is the
first thing the randomized-program oracle runs against, and every later
module is checked against it.
