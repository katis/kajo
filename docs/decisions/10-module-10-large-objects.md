# Module 10: large objects

Module 10 (large objects, built 2026-11-06, `docs/modules/large-objects.md`,
ADR 0003's and 0007's Built (10) notes): an object past one 32 KiB block
(4095 slots) is a run of contiguous blocks, one head and continuations in a
one-byte-per-block kind table, allocated old, never young, never relocated
or compacted, its largeness read from the header's count (no header bit),
the limit the 24-bit count field (16 777 215 slots, 128 MiB, or 16 MiB - 1
bytes); every reader of a body walks runs (verifiers, both sweeps, the block
pool, compaction, the relocator and its verifier, snapshot writer and
loader, reshape, become); the marker scans a large object 4096 slots at a
time and polls by work done; a large allocation decides module 5's trigger
and starts the cycle from the allocating worker's young collection with the
object a pending root (the first version rooted it only in its own stop and
the random programs crashed); a full collection forced by an old allocation
counts as module 5's fallback; image version 5 (snapshot 4), versions 1 to 4
refused naming module 10, fuzz seeds upgraded plus `large-objects.img`; the
kernel back to plain Arrays (`LargeArray` and `Array class>>large:` gone,
`basicNew:` names the limit), the transport's request limit 16 MiB - 1 with
replies still in pieces; vm-teardown's two items built (old space grows for
the VM's final collection out of address space reserved with the heap,
`Image.saveImage` throws `processesHaveFrames` naming `Smalltalk
snapshot:`); the random programs gained a large-object step and the shells
`scenario=large`; measured on the mini: 1 MiB allocate p50 0.044 ms and 16
MiB 0.62 ms, freeing them 0.020 ms, `at:`/`at:put:` on a million elements
1016 ms against `LargeArray`'s 4567, marking a 1M-slot Array 0.8 ms in 244
chunks with 0.013 ms between polls, the large churn scenario 0 of 1200
frames missed with 811 to 819 cycles per 10 s all started by large
allocations, the 2000-class image 481 ms against 518, `package.selectors`
443 ms against 657 and 19 866 rows pushed in 36 ms against 108, bench within
noise and `interpret` identical, worst-case fragmentation 1.64 times live
data (683 free blocks with no three adjacent), 46 new `unsafe` sites in the
object memory and marker; four test bounds of earlier modules widened under
the sanitizer only or repeated a round (9d's listener pause and 9b's
evaluate under ThreadSanitizer with load, the relocation fragment kernel's
two selecting cycles, the exhausted-reserve heaps two blocks larger); not
done: no card table for large objects (a remembered one is scanned whole by
a scavenge), filling a large object does not poll (about 5 ms at 128 MiB),
runs never move so fragmentation between them persists, LargeIntegers stay
one block, nothing ran on the iPhone; the owner answered its four questions
on 2026-11-06: 16 MiB is too little for bytes if images or photos sit in a
ByteArray (the limit is to be lifted in a follow-up), runs are never
relocated, no card marking yet, and the pieces stay until the follow-up has
measured them against one String; after the device run the owner also asked
for the large-churn fallbacks to be tuned away on devices (such churn is
plausible in a photo or video app), for an investigation of the iPad's three
unexplained readings, and for the 2000-class image to be served from a
device.
