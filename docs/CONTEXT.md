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

- **Oop**: a 64-bit tagged word. Low bit 1: a SmallInteger, 63-bit two's
  complement. Low four bits 0 and nonzero: an object reference, the byte
  offset of the object's entry in the entry table (ADR 0003). The other
  low-nibble patterns are reserved for future immediates. 0 is no object.
  Oops never change when objects move.
- **Entry**: 16 bytes in the entry table: the state word (the body's offset
  in the heap, offset + 2^32 while RELOCATING, or a free-list link with bit
  63 set) and the header word. Entry 0 is never used.
- **Header**: the object's header word, kept in its entry, not in the body.
  Bits 0..21 class index, 22..45 slot or byte count, 46 mark (reserved;
  marks live in a side byte map), 47 byte object, 52..55 nursery index, 56
  young, 57..59 age, 60 pinned for good, 61 frame pin, 62..63 scavenge
  claim tag. Written only with the world stopped.
  docs/modules/object-memory.md has the full layout and which bits each
  module uses.
- **Body**: an object's storage in the heap: a back reference (entry index
  and body size) then the slots or bytes. Never spans a block.
- **Block**: 32 KiB unit of the heap; bodies are bump-allocated in blocks.
- **Allocation context**: a caller's private block and private free-entry
  list; one per worker.
- **Pin**: a header bit that keeps a body from moving. Pinned for good:
  objects the interpreter holds raw pointers into. Frame pin: objects a
  running frame names, for the current collection only.
