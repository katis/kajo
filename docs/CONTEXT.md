# Kajo context

Shared vocabulary for the project. When a word here is used in code, docs or
conversation it means exactly this. Add words as they are coined; sharpen them
as they are understood.

## System

- **VM** or **VM core**: the Swift library `KajoVM`. Object memory, garbage
  collector, interpreter, scheduler and primitives. The trusted computing
  base: the only code that can corrupt memory.
- **Shell**: a native macOS or iOS application that hosts a VM and renders its
  UI with SwiftUI, UIKit or AppKit. Owns the main thread. Never runs
  Smalltalk code on it.
- **Image**: a snapshot of the whole object memory. Loaded at startup, saved
  at will. A build artifact, never committed.
- **Kernel**: the Smalltalk class library that boots the system, kept as text
  under `kernel/`.
- **Development protocol**: the connection between a shell or VM being
  developed and the developer's tools on another machine. Not designed yet.

## Execution

- **Worker**: an OS thread that executes Smalltalk processes. Many workers
  share one heap.
- **Process**: a Smalltalk-level thread of control, scheduled onto workers.
- **Safepoint**: a point where a worker checks whether it must pause for the
  collector. Reached at sends and backward jumps.
- **Primitive**: VM-implemented behaviour reachable from Smalltalk by send.
  The boundary where the VM checks bounds and types so Smalltalk code can
  never corrupt memory.

## Memory

- **Oop**: a 64-bit tagged word that is either a SmallInteger or an object
  pointer. The exact tag scheme is an open decision.
- **Header**: the first word of a heap object. Packing is an open decision.
