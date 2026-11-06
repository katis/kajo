# Large bytes: where a long byte object keeps its length

The representation experiment of `docs/modules/large-bytes.md`, part 1,
2026-11-06, Mac mini (M2 Pro), swift.org 6.4.2, `swiftc -O bench.swift`.
Two candidates for a byte object longer than the header's 24-bit count
field, compared on the paths a small object takes (the brief's
constraint: those paths unchanged, or within noise):

- **A, sentinel.** The count field is exact below S = 2^24 - 8. At or past
  S it holds `S | n & 7` and the length comes from the back reference's
  words. The field is never more than the length, so the fast bounds check
  stays `i < count` and only its failure (out of line already) asks for
  the true length; `size` asks when the field is at least S on a byte
  object.
- **B, words.** The count field of every byte object is its body's words
  and three header bits hold the padding (bits 46 and 51 are free, a
  third has to move from another field). Every byte object's length,
  small ones included, is `(words << 3) - pad`.

The third candidate of the brief (a wider count field, 64 MiB) was not
built: it does not reach a photo and spends the last free bits.

## Instructions (arm64, `-O`)

| path | today | A, sentinel | B, words |
|---|--:|--:|--:|
| bounds check `i < length` | `ubfx`, `cmp` | the same | `lsr`, `and`, `ubfx`, `sub`, `cmp` |
| `size` of a byte object | `ubfx` | `ubfx`, `tbz` bit 47, `mov`, `cmp`, `b.lo` (the long path a tail call) | `lsr`, `and`, `ubfx`, `sub` |

## Time (4096 small ByteArrays of 1 to 4000 bytes, 2000 passes, best of 7, three runs)

| path | today | A | B |
|---|--:|--:|--:|
| check | 0.88 to 0.99 ns | (today's) | 0.88 to 0.91 ns |
| size | 0.88 to 0.92 ns | 1.18 to 1.23 ns | 0.88 to 0.92 ns |

Both agree with the true length on every one of the 4096 objects, and A
answers 1 073 741 827 for a 1 GiB + 3 byte object whose fast check admits
16 777 207 and refuses 16 777 211 (the slow path decides it).

## What it showed

The loop's own cost hides one or two instructions in time; the
instruction counts are what the dispatch loop would see. B adds three
instructions to every byte bounds check, small objects included, and
changes the meaning of every reader of a byte count (the module lists
about forty); A adds nothing to the check and one compare-and-branch to
`size` on a byte object, which in the VM sits in the special-send tier's
`size` arm, not in `interpret`. A also needs no header bit: the odd bytes
ride in the sentinel's low three bits. **Chosen: A.** The VM's diff of
`interpret` against the starting commit is in the module doc.
