# Build plan: from the experiments to `Sources/KajoVM`

Status: started 2026-11-02; modules 1 to 4 built the same day, modules 5 to 7 and 8a to 8c the next two days, 8d, 8e and 9a (Mac and iPhone) on 2026-11-04, 9b, 9c and 9d (Mac to Mac) on 2026-11-05, 10 and the devices' rows of 9a and 9d (iPhone and iPad) on 2026-11-06; the relocation, young-collection and save-hold
models (`docs/models/`) are checked. A follow-up for two latent crashes (the stop-the-world oracle's promotion reserve, the parser's depth against a thread stack) was built 2026-11-04: `docs/modules/reserve-and-depth.md`, with two open questions for the owner. A second follow-up the same day made the image whole when the VM ends and closed the file primitives' last link: `docs/modules/vm-teardown.md`, two open questions for the owner. A step or two at a time; the order below is the
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
| 7 | **Young collection without stopping the world** (built 2026-11-03, `docs/modules/young-collection.md`) (ADR 0008), mixed QoS policy | concurrent-young, power | model check of the handshake and epoch freeing (done: `docs/models/young-collection.md`) |
| 8 | **Kernel, compiler, image build**: Smalltalk sources under `kernel/`, a compiler in Smalltalk bootstrapped from a Swift one or from kasm, the first image | 8a (the VM side) built 2026-11-03: `docs/modules/object-model.md`; 8b (kernel sources, bootstrap compiler, compiler in Smalltalk, image build, test harness, weak symbol table) built 2026-11-03: `docs/modules/kernel-image.md`, with five open questions for the owner; 8c (Processes saved in the image, decided 2026-11-03) built 2026-11-04: `docs/modules/image-processes.md` with the save-hold model and six open questions for the owner; the owner answered 8b's and 8c's questions 2026-11-04, and 8d (Pharo's per-iteration temp vectors, class variables, installing from Smalltalk behind a release flag, `Behavior>>compile:` and `Compiler evaluate:`) built 2026-11-04: `docs/modules/kernel-live.md`, image format 3, four open questions for the owner; 8e (live classes: defining, reshaping and removing classes from Smalltalk, categories and comments in the image, the Tonel writer and reader in Smalltalk, `kernel/` in the canonical form the image writes with a byte-identical round-trip test) built 2026-11-04: `docs/modules/live-classes.md`, five open questions for the owner; brief `docs/modules/kernel.md` | module 3 at least |
| 9 | **Shells and development protocol**: macOS and iOS apps, remote development | 9a (the shells on the Mac and the iPhone 13 Pro, the host surface, the first view wrappers as ADR 0010, the device measurements ADRs 0003 to 0008 wait for) built 2026-11-04 on the Mac: `docs/modules/shells.md`, ADR 0010 proposed, the Mac matrix measured; the iPhone 13 Pro ran the tests and the matrix 2026-11-04 (recorded in shells.md and ADRs 0003, 0004, 0008), and the owner accepted ADRs 0004 to 0008 and 0010 the same day; 9b (the protocol, the debugger with stepping and define-and-proceed, sources to the project with extension files and author marks, MCP and CLI, obsolete classes freed, extensions on sealed classes, terminate unwinding) built 2026-11-05: `docs/modules/development-protocol.md`, ADRs 0011 and 0012 proposed, image version 4, five open questions for the owner; 9c (the developer UI as the Smalltalk package `tools/` in a development image built with `--with`, the client transport primitive 164, the second round of wrappers, browser, workspace, inspector, debugger, test runner, transcript and target picker, `LargeArray` and pieced lines because no object passes one heap block, the scripted session and typing measured on the Mac mini's display) built 2026-11-05: `docs/modules/developer-ui.md`, ADR 0013 proposed, ADR 0010's Built (9c) note, five open questions for the owner; 9c's five questions answered by the owner 2026-11-05 (a large-object space in the VM as a module of its own, push by default and on demand for long lists, errors stop for the debugger, apps against a second target image, no token in the image); 9d (the phone transport: TCP and Bonjour beside the Unix socket, the pairing token on the phone's screen and in the host's secure field, the failure limits, `TargetAddress` for `ClientHost`, the Swift client, CLI and MCP, reconnect with retry of the idempotent requests, the scripted session against another target) built 2026-11-05 and measured Mac to Mac: `docs/modules/phone-transport.md`, ADR 0011's Built (9d) note, six open questions answered by the owner 2026-11-05 (plain TCP now, PSK-TLS later, no token expiry, any number of sessions, serving by launch argument only, doits not resent); the phone's rows ran in part 2026-11-06 (the iPhone serving with no client: 0 of 2400 frames missed; client rows blocked by macOS Local Network privacy for the session and iOS's local-network permission, the iPad's build by Xcode's missing account; recorded in `docs/modules/phone-transport.md` "On the devices"; `ViewWrapperTest` assumed the headless host and was fixed the same night, 202 of 202 headless, Mac shell and iPhone); the rest ran later on 2026-11-06 once the owner cleared the blockers (5a180c2): the iPad Pro 12.9-inch 3rd generation passes 202 of 202 and keeps every frame of the matrix at 5 workers, 74 remote sessions over Wi-Fi against the iPhone and the iPad with no failure and no frame missed while serving, the class tree keeps the push form; left: the iPad's Bonjour rows (its local-network permission) and three unexplained iPad readings (event latency under the storm, Wi-Fi request maxima, energy); the collectors' first external review (pull request 1, 2026-11-06) found nine things, three of them bugs a program can hit (the replace primitive without the weak keep-alive barrier and with an overflow trap, unbounded collection logs), being fixed as a follow-up; the large-object space is module 10, built; ui-thread-scheduling's kajo-ui, device-measurement app | module 8 |
| 10 | **Large objects**: a large-object space inside the block heap (runs of blocks, old at birth, never moved, image version 5), the kernel back to plain Arrays, the transport's one-block limit lifted, old space growing for the VM's final collection and the host save refusing with live Processes (vm-teardown's owner answers) | briefed 2026-11-05 from the owner's answer to 9c's first question; built 2026-11-06 (code 7987f59): `docs/modules/large-objects.md` as built, image version 5, ADR 0003's and 0007's Built (10) notes, vm-teardown's two items closed, measured on the Mac mini (16 MiB allocate 0.62 ms, million-element `at:put:` 4.5 times faster than `LargeArray`, large churn 0 of 1200 frames missed), four open questions for the owner | module 9 |
| later | **Distribution** (the owner's shape, 2026-11-05): `Kajo.dmg`, one Mac app with the development image, its tools editable in place, and a wizard that generates an app project (Mac and iOS targets on one Tonel directory, Debug with the development image and protocol, Release without, a pinned Kajo dependency); the phone runs the developer's own development build from Xcode, so no Kajo app meets App Review; serving as a property of the development build with the pairing screen in the running app; the on-phone snapshot and UIKit wrappers from `docs/modules/phone-transport.md`'s later needs; a teaching playground app for iPhone and iPad is a later idea | not briefed | modules 9 and 10 |

Modules 1 to 3 give a VM that runs kasm programs on many workers with a
stop-the-world collector and a frame-budgeted main thread. That is the
first thing the randomized-program oracle runs against, and every later
module is checked against it.
