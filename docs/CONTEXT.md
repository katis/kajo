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
  marks live in a side byte map), 47 byte object, 48 fired ephemeron,
  52..55 nursery index, 56 young, 57..59 age, 60 pinned for good, 61 frame
  pin, 62..63 scavenge claim tag. Written only with the world stopped, or
  by the allocating worker before the oop escapes.
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
- **Nursery**: a worker's region for young objects (module 4): an eden
  and two survivor halves, beyond the block range. Every worker has one;
  all are collected together by a scavenge.
- **Eden**: the part of a nursery new objects are bump-allocated in; empty
  after every scavenge.
- **Survivor**: a young object that lived through a scavenge, copied into
  the copying participant's survivor-to half; survivor-from holds the
  previous scavenge's survivors. The halves swap roles at every scavenge.
- **Young / old**: young objects live in a nursery (header bit 56); old ones
  in blocks. Promotion copies a young object into old space; its oop stays.
- **Age**: the scavenges a young object survived (header bits 57..59). At
  N (default 2) it is promoted; earlier when survivor-to is full (an
  overflow promotion).
- **Scavenge**: a stop-the-world young collection: every participant
  copies the young objects reachable from the roots and the remembered
  holders, then the dead young entries are freed.
- **Claim tag**: header bits 62..63; scavenge s claims a young object by
  setting bit 62 + (s & 1) in one compare-and-swap that also writes the
  decision (survive or promote). A loser reads the decision.
- **Remembered set**: the old objects that may name a young one: a 16-bit
  marker per entry beside the table (one bit per nursery) and per-worker
  buffers of holders. Never a header bit; never a young holder.
- **Barrier**: the check after every store of an oop into a heap object:
  a young value stored into an object not young in the same nursery calls
  the slow path, which remembers an old holder.
- **Promotion reserve**: blocks beyond old space's soft limit that only
  promotion may take, so a scavenge never fails for lack of space.
- **Entry stash**: an array of free entries owned by one nursery; young
  objects take entries from it in order, and the entry sweep returns the
  dead ones to it.
- **Weak slot**: an indexed slot of an object whose class format is weak:
  not traced; nil once its referent is reclaimed.
- **Ephemeron**: an object whose slot 0 (the key) is traced only if the key
  is reachable some other way; when it is not, a full collection fires the
  ephemeron once: queues it for finalization and keeps key and value alive
  for that collection.
- **Format**: a class's format word beside the class table: named slots,
  and weak or ephemeron (ADR 0009 section 6). The header keeps only
  pointers or bytes.
- **Finalization queue**: the fired ephemerons, a root, taken one at a
  time by a Process that a Semaphore wakes; finalizers never run on a
  collector thread.
