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

- **Worker**: an OS thread that executes Smalltalk Processes, with its own
  interpreter state, lookup cache and allocation context. Many workers share
  one heap. Worker 0 is the **main worker**: the shell's main thread, inside
  the VM only during a Turn. Background workers are threads of the VM at
  user-initiated QoS; the host worker serves host calls. Idle workers wait
  untimed.
- **Process**: a Smalltalk-level thread of control, scheduled onto workers:
  a heap object (class 13: priority, state, affinity, saved registers as
  integers, result, exit Semaphore), a native record and its own stack. It
  can leave one worker mid-method and resume on another. A **main-affine**
  Process runs only on the main worker.
- **Semaphore**: a heap object (class 14): excess signals and a FIFO list of
  waiting Processes. The only way a Process waits; primitives never block.
- **Safepoint**: a point where a worker checks whether it must pause for a
  stop, and every `pollEvery` polls its budget. Reached at sends and
  backward jumps. A **stop** brings every worker inside the VM to a
  safepoint (parked) so one of them can collect, compact or become.
- **Turn**: one call of the shell into the VM on the main thread
  (`runMain`): main-affine Processes run until none is ready or the turn's
  budget is spent; a Process that overruns is preempted at its next budget
  check.
- **Hop**: a primitive that must run on the main thread, called on another
  worker, suspends its Process with the send rewound, makes it main-affine
  and wakes the main worker, which retries the send.
- **External signal**: a Semaphore signal from a thread outside the VM (a
  completion handler, the shell), pushed onto a lock-free queue that workers
  drain at budget checks, turns and when they wake. A **pending root** keeps
  the Semaphore alive until it is drained.
- **Primitive**: VM-implemented behaviour reachable from Smalltalk by send.
  The boundary where the VM checks bounds and types so Smalltalk code can
  never corrupt memory.

- **Stack**: a region of tagged words, outside the heap, that frames live
  on. Word 0 is nil and every word up to sp is a valid oop, so the collector
  scans it uniformly. Module 3 gives one to each Process.
- **Frame**: one activation on a stack: receiver, arguments, temps, then a
  five-word header (method, caller pc, caller fp, caller hdr, and the
  frame's Context, nil until materialized: ADR 0009) and the operand stack. The caller links are SmallIntegers holding a bytecode
  offset and word indices, never addresses, so neither moving bytecodes
  nor a moving stack needs them fixed.
- **Send**: finding and running the method for a receiver's class and a
  selector: the lookup cache, else the superclass chain's method
  dictionaries; then the method's primitive, or a new frame. With no
  method, `doesNotUnderstand:` is sent with a Message if the class has it.
- **Primitive failure**: a primitive refusing its receiver or arguments
  (wrong type, bound or argument count). The method's bytecodes then run
  as an ordinary activation; a method with none stops with a VMError.
  Running out of heap is not a primitive failure.
- **VMError**: what a program that cannot go on hands its caller: kind,
  selector, receiver class, method and pc. The interpreter never exits or
  traps on one and leaves the stack as it was for inspection.
- **Structural class**: Class, Method and MethodDict, the objects whose
  shape the interpreter trusts. No primitive reads, writes, creates or
  exchanges their instances.

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
