# experiments

Throwaway spikes that answer a design question before it is locked in. One
directory per experiment with its own design brief and results. They stay in
the tree so ADRs can point at the evidence, and may be deleted once nothing
references them.

| Directory | Question | Outcome |
|---|---|---|
| `vm-language-bench/` | Rust or Swift for the VM core? | Swift. See `docs/adr/0001-swift-for-the-vm-core.md` |
| `object-representation/` | Direct pointers with forwarders, an object table, or heap offsets? | Object table, proposed. See `docs/adr/0003-object-representation.md` |
| `ui-thread-scheduling/` | Does the Smalltalk UI Process on the main thread, with budgeted preemption, Process-owned stacks, hop-to-main and GCD-signalled Semaphores, hold an AppKit window's refresh rate, and what does it cost? | Holds at 120 Hz except across GC pauses. Proposed in `docs/adr/0004-smalltalk-on-the-main-thread.md` |
| `generational-gc/` | Does a generational nursery on the object table VM keep young-collection pauses inside a 120 Hz frame while eight workers allocate, what does the write barrier cost, and does the main thread hold 120 Hz under the earlier allocation storm? | Nursery adopted; scavenges fit a frame for low survival, full collections still drop frames. Proposed in `docs/adr/0005-generational-collection.md` |
