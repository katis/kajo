# The reserve-and-depth follow-up

The stop-the-world scavenge trapped when its promotion reserve ran out, the
ring at 600 MiB, fixed in the reserve-and-depth follow-up,
`docs/modules/reserve-and-depth.md`: the cause was the fallback, not the
reserve's size, a mark-sweep that could not bring old space under its soft
limit, so a full collection now compacts when the sweep leaves old space
past the limit, a stop-the-world scavenge keeps in place what finds no block
and requests the full collection, a module 7 young collection opens only
with its promotion room promised under the pools lock and otherwise stops
the world for module 4's scavenge, become, reshape and the save refuse with
a heap full of live data, two random-program configurations run with no
reserve; the ring at 600 MiB under the oracle now finishes every run,
missing 143 of 1200 frames to compacting full collections of 250 ms where
the concurrent modes miss none; the same follow-up walks message chains by
loops in the bootstrap compiler, lowers the nesting limit to 32 in both
compilers after measuring 4 to 9.5 KB of debug stack per level, and runs the
syntax fuzzer on a 512 KB thread; its two open questions answered by the
owner on 2026-11-04 (the oracle's misses are acceptable, the limit stays
32).
