# Shared spec for the Rust and Swift slices

Both implementations are written against this file. If one changes, the other
changes the same way.

## Values (tagging)

- 64-bit words. Low bit 1 = SmallInteger, value = `word >> 1` (arithmetic).
  Range is 63-bit signed: `-(2^62) .. 2^62-1`. `mkInt(i) = (i << 1) | 1`.
- Low bit 0 = direct pointer to an object header (8-byte aligned).
  No object table. `0` is never a valid value.
- `nil`, `true`, `false` are ordinary 0-slot objects of classes
  UndefinedObject, True, False.
- Arithmetic on tagged words (no untagging):
  - `a + b` = `a + (b - 1)` with signed overflow check
  - `a - b` = `a - (b - 1)` with signed overflow check
  - `a * b` = `(a >> 1) * (b - 1) + 1` with overflow check on the multiply
  - `< > <= >= =` compare the tagged words as signed i64 (monotonic)
  - overflow or a non-SmallInteger operand falls back to a real send of the
    special selector (there is no LargeInteger, so in practice this aborts
    with doesNotUnderstand).

## Object header (one u64)

| bits   | field                                             |
|--------|---------------------------------------------------|
| 0..21  | class index (22 bits)                             |
| 22..53 | slot count (32 bits); for byte objects, byte count|
| 54     | mark bit                                          |
| 55     | format: 1 = bytes, 0 = pointer slots              |
| 56..63 | spare, always 0                                   |

Object size in bytes = `8 + (bytes ? roundUp(n, 8) : 8 * n)`.
Byte objects are zero-filled, pointer objects are nil-filled on allocation.

## Well-known class indices

| idx | class           | idx | class      |
|-----|-----------------|-----|------------|
| 0   | (invalid)       | 6   | Method     |
| 1   | SmallInteger    | 7   | Array      |
| 2   | UndefinedObject | 8   | ByteArray  |
| 3   | True            | 9   | Symbol     |
| 4   | False           | 10  | MethodDict |
| 5   | Class           | 11  | Object     |

User classes from .kasm get 12, 13, ... in declaration order (prelude first,
then the kernel file). All builtin classes except Object have superclass
Object; Object's superclass is nil. The class table is a plain array of 1024
class-object pointers (index 0 unused).

Class object (class index 5), 5 slots:
`0 superclass, 1 methodDict, 2 name (nil), 3 instSize (int), 4 classIndex (int)`.
There are no metaclasses: every class object is an instance of `Class`, so
"class-side" primitives (`basicNew`, `new:`) are defined on `Class` and read
the receiver's slots 3 and 4.

Method object (class index 6), 7 slots:
`0 bytecodes (ByteArray), 1 literals (Array), 2 argc, 3 ntemps, 4 maxStack, 5 selector, 6 primitive (0 = none)`.

Symbol (class index 9): 1 slot, `0 id (int)`. Ids are sequential in intern
order. Symbol names live on the host side only.

MethodDict (class index 10): pointer object with `2 * cap` slots,
`cap` = smallest power of two >= max(8, 2 * count). Key at `2i`, method at
`2i+1`, empty key = nil. Hash = `(selectorPointer >> 3) & (cap - 1)`, linear
probing. Lookup walks superclass chain; reaching nil aborts (DNU).

## Boot / allocation order (identical in both, so heap layout matches)

1. Allocate `nil`, `true`, `false` (0 slots).
2. Allocate class objects for indices 1..11 in index order, then fill their
   slots (superclass, instSize, classIndex; methodDict nil for now).
3. Intern special selectors in order: `+ - * < > <= >= = ==`.
4. For each .kasm file (prelude, then kernel): allocate class objects for
   each `class` line in order (superclasses resolved after all class lines of
   that file). Then for each `method` in source order: intern the method
   selector, then each literal symbol in literal-frame order; allocate the
   bytecode ByteArray, the literal Array, then the Method.
5. After all files: for each class index ascending that has methods, allocate
   its MethodDict and insert methods in source order.
6. Boot allocations use a boot TLAB which is retired afterwards.

## Bytecodes (1-byte opcode, operands follow)

| op   | name          | operands                 | effect |
|------|---------------|--------------------------|--------|
| 0x00 | push_temp     | u8 n                     | push fp[1+n] (args are temps 0..argc-1) |
| 0x01 | push_lit      | u8 n                     | push literals[n] |
| 0x02 | push_self     |                          | push receiver |
| 0x03 | push_ivar     | u8 n                     | push receiver slot n |
| 0x04 | store_temp    | u8 n                     | pop into temp n |
| 0x05 | store_ivar    | u8 n                     | pop into receiver slot n |
| 0x06 | pop           |                          | |
| 0x07 | dup           |                          | |
| 0x08 | push_nil      |                          | |
| 0x09 | push_true     |                          | |
| 0x0A | push_false    |                          | |
| 0x0B | push_int      | i8                       | push SmallInteger |
| 0x0C | send          | u8 litIndex, u8 argc     | send literals[litIndex] |
| 0x0D | return_top    |                          | |
| 0x0E | return_self   |                          | |
| 0x0F | jump          | i16 LE                   | pc += off (relative to next instr) |
| 0x10 | jump_if_true  | i16 LE                   | pop; jump if true; non-boolean aborts |
| 0x11 | jump_if_false | i16 LE                   | pop; jump if false; non-boolean aborts |
| 0x12..0x19 | add sub mul lt gt le ge eq |      | special sends, SmallInteger fast path |
| 0x1A | identical     |                          | `==`, always inline |

Note: `store_*` pops (pop-and-store). Any other opcode aborts.

## .kasm text format

```
; comment to end of line
class <Name> <Superclass> <instSize>
method <Class> <selector> temps=<n> [prim=<k>]
  <label>:
  <opname> [operand]
end
```

- Operands: `push_temp/push_ivar/store_temp/store_ivar n`, `push_int n`
  (-128..127), `push_lit <lit>`, `send <selector> <argc>`, jumps take a label.
- Literals: decimal integer, `#selector`, `@ClassName`, `nil`, `true`, `false`.
  The assembler builds the literal frame in first-use order and dedups.
- argc of a selector: binary (first char not a letter) = 1, keyword = number of
  `:`, unary = 0. `send`'s argc must match.
- `maxStack` = maximum operand-stack depth by linear scan.
- A method with `prim=k` has no body (just `end`).

Primitives (failure aborts the program; there is no fallback code):
`1 Object>>at:`, `2 Object>>at:put:`, `3 Class>>basicNew: / new:`,
`4 Class>>basicNew`, `5 Object>>class`, `6 SmallInteger>>//`,
`7 SmallInteger>>\\` (floor semantics). 4, 6 and 7 are additions to DESIGN.md:
`basicNew` creates fixed-size instances, `//` divides the work between workers.

Kernel entry: the host sends `run:of:` to `nil` with `(workerIndex, workerCount)`
on each worker. Checksum = wrapping i64 sum of the worker results.

## Frames (per-worker word stack, grows up)

Stack: 64Ki words per worker. `stack[0]` holds nil; `sp` points at the last
pushed word. A frame, with `fp` pointing at the receiver:

```
fp[0]            receiver          (pushed by caller)
fp[1..argc]      arguments         (pushed by caller)
fp[1+argc..]     temps (nil)
hdr[0]           method            hdr = fp + 1 + argc + ntemps
hdr[1]           caller pc   (mkInt(address))
hdr[2]           caller fp   (mkInt(address), mkInt(0) = return to host)
hdr[3]           caller hdr  (mkInt(address))
hdr[4..]         operand stack
```

Every word in `stack[0..=sp]` is a valid tagged value, so the GC scans stacks
uniformly. Activation checks `hdr + 4 + maxStack < stackEnd`.
Return writes the result over the receiver slot and sets `sp = fp`.

## Lookup cache

Per worker, 1024 entries `{classIndex u64, selector u64, method u64}`,
direct-mapped, index `((selector >> 3) ^ classIndex) & 1023`. Miss: full
lookup, overwrite entry, count a miss. No per-call-site caches.

## Heap, TLAB, GC

- One `mmap` arena of 64 MiB, 2048 blocks of 32 KiB. Objects never span
  blocks; objects larger than a block abort.
- Free-block pool: array of block indices + `count` + atomic `next` cursor.
  A worker takes a block with `fetch_add(next, 1, relaxed)`; if the result is
  `>= count` there is no free block and the worker requests a GC, then retries
  once; still none = out of memory, abort.
- TLAB = bump pointer into the worker's current block. Retiring a TLAB records
  the block's `used` byte count (the block is not reused for allocation until
  it is completely empty).
- **Sweep choice (the simpler option in DESIGN.md):** TLABs are carved only from
  completely empty blocks. Sweep walks every in-use block linearly, clears
  mark bits of live objects, and returns blocks with no live objects to the
  pool. Partially live blocks are left alone. The pool is rebuilt in block
  index order.
- Mark: single-threaded, iterative, explicit mark stack; roots are the class
  table, host-side globals (nil/true/false, all symbols), and every worker's
  stack `[0, sp]`. The mark bit is set when an object is pushed.

## Safepoint protocol

- Global atomic `gcRequested` (bool). Polled with a relaxed load at every send
  (including special-op fallbacks) and every backward jump. Ordering is
  carried by the mutex.
- Shared state under one mutex + condition variable: `active` (workers still
  running Smalltalk), `parked`, `epoch`.
- Worker that sees the flag: flush `sp`, retire TLAB, lock. If the flag is
  already clear, return. Else `parked += 1`, broadcast, wait until `epoch`
  changes, `parked -= 1`.
- Worker that needs a GC: flush `sp`, retire TLAB, lock. If the flag is already
  set, park as above (someone else collects) and retry. Else store flag
  (release), wait until `parked == active - 1`, collect, clear flag (release),
  `epoch += 1`, broadcast.
- Worker that finishes: lock, `active -= 1`, broadcast.
