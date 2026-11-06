# Large bytes (a follow-up to module 10)

Status: brief, 2026-11-06. From the owner's answers to module 10 and to
the device run of the same day (`docs/modules/large-objects.md`, "The
owner's answers"; `docs/modules/shells.md`, the large-churn rows). The
module that builds this rewrites the file as the as-built description.

Three things, in this order of weight:

1. A byte object may be larger than 16 MiB - 1 bytes. The owner: "16 MiB
   might be too little if you have images or photos in a ByteArray." A
   decoded 12-megapixel photo is 48 MiB of RGBA, a 48-megapixel one 192
   MiB, a 4K frame 33 MiB.
2. The churn of large objects that `scenario=large` makes does not fall
   back to a stop-the-world collection on the devices (3 of 6 device runs
   counted fallbacks, none on the Mac). The owner: such churn is likely in
   a photo or video app, so tune it for devices.
3. The transport's pieces are measured against one String per line, and
   the cheaper form stays. The owner asked whether keeping the pieces is
   right; the reason given so far is an argument, not a number.

Not in this follow-up: relocating runs (the owner: never), card marking
for large pointer objects (the owner: not yet), LargeIntegers past one
block, a native image type behind a handle (an app may still prefer one
for decoded pixels; that is a wrapper's decision, later), file or network
primitives that fill a ByteArray.

## What it hides

How long a byte object can be and where its length lives. Smalltalk sees
`ByteArray new: n`, `String new: n`, `size`, `at:`, `at:put:` and the
copying primitives work for any `n` up to the new limit, and `basicNew:`
names that limit when it refuses. Nothing above the object memory learns
whether the length is in the header.

## 1. Bytes past the count field

The header's count is 24 bits (bits 22 to 45; `Header.swift`). Bits 46
and 51 are reserved. A large object's body starts with the back reference
every body has, which already holds the body's size in words in 32 bits.

**The constraint that decides the design:** the dispatch loop and the
fast paths of `at:`, `at:put:` and `size` on objects that fit the field
are unchanged instruction for instruction, or the change is measured in
aligned A/B builds and within noise on every kernel (`interpret` diffed,
`just arc-check`, five runs interleaved at 1 and 8 workers, as module 10
did). `storeheavy` paid 7 to 10 percent for one header-bit test; this
follow-up must not add another to a path a small object takes.

Candidates, to be compared by a small experiment before the code:

- **A sentinel count.** A byte object longer than the field holds stores
  the field's maximum, and its true length lives elsewhere: derived from
  the back reference's words plus a few bits for the odd bytes, in the
  head block's side-table record, or in a word of the run. An index below
  the field's maximum is in bounds without reading the true length, so
  the existing bounds check stays the fast path and only its failure path
  (already out of line) asks whether the count is the sentinel. `size`
  gains one compare on its slow side.
- **A count in words for byte objects**, with the odd bytes in spare
  header bits. This changes what the count means for every byte object,
  small ones included, and every reader of a byte count; only two header
  bits are free and three are needed, so it also moves a field.
- **A wider count field** (both reserved bits: 64 MiB) does not answer the
  owner's case and spends the last two bits. Not this.

Choose, say why, and record what the experiment showed. Whatever is
chosen:

- **The limit** is stated as a constant with its reason (at least 1 GiB;
  the heap's reservation and a device's memory limit bound it in
  practice), `basicNew:` and every allocating primitive refuse past it
  with the kernel's error, before any arithmetic on the argument
  (`ExtremeIntegerTests` gains the new boundary values: the old limit, the
  old limit + 1, the new limit, the new limit + 1).
- **Pointer objects keep the 24-bit limit** (16 777 215 slots, 128 MiB)
  unless the chosen mechanism lifts it at no cost to the marker, the
  scavenge's remembered scan and the verifiers; if it could, say what it
  would take and leave it as a question.
- **Every reader of a byte count is listed in one table** in the doc, as
  the collectors review listed weak-slot readers: allocation, `size`, the
  bounds checks, `bodyBytes`, the copy and replace primitives, string
  compare, hash, search and the UTF-8 primitives, `shallowCopy`, become,
  reshape's refusal, the sweeps and the block pool, the verifiers, the
  marker (a byte object is not scanned, but its size is accounted), the
  snapshot writer and loader, the protocol's reply path, the host
  surface's `ShellValue` conversions. Each row says where the true length
  comes from after the change.
- **No primitive over bytes keeps a stop waiting.** Module 10 left filling
  a large object unpolled: 0.6 ms at 16 MiB, about 5 ms at 128 MiB. At 1
  GiB a fill, a copy, a compare or a hash is tens to hundreds of
  milliseconds during which every stop waits for that worker, and a stop
  that waits is a main thread that waits. Measure each such primitive at
  the new limit, and bound the longest stretch a worker spends in one
  without being stoppable (the marker's chunks are the precedent: 4096
  slots, polled by work done). A run never moves and bytes hold no
  references, which may let the long loops run as module 7's blocking
  regions do; whichever way, the bound is a test that counts the longest
  unstoppable stretch in work done, not in wall-clock time, and a broken
  variant shows it failing.
- **The image format** changes if the true length is not in the header
  the snapshot already writes: a new version, older ones refused naming
  this follow-up, the loader checking the length against the run's blocks
  before trusting it (a length that does not fit its run is a refusal and
  a fixture), the fuzz seeds upgraded and one seed with a byte object
  past the old limit.
- **The random programs** gain a byte object past the old limit in their
  large-object step (in the configurations that can afford it; say which
  and why), and `LargeObjectTest` its tests in the kernel.

Measure, on the Mac mini and on both devices: allocating and freeing 16,
64, 256 MiB and 1 GiB byte objects (the devices as far as their memory
allows; report the footprint and where the limit was), `at:` and
`at:put:` over the whole of one, `replaceFrom:to:with:startingAt:` of
one into another, the longest unstoppable stretch in each, and frames
missed in a scenario that allocates, fills and drops photo-sized
ByteArrays (48 MiB) on a background worker while the main thread
animates.

## 2. Large churn on the devices

`scenario=large` on the devices counted module 5 fallbacks
(`fallbacksIdle`, with as many stop-the-world scavenges) in 3 of 6 runs,
at thermal serious, costing no frame; the Mac counted none in any run.
Find out why before changing a number: which resource ran out (old
space's soft limit, blocks with no run of the needed length, the entry
table), how far the marker was into its cycle when it did, at what QoS
and on which cores the marker ran (utility, so efficiency cores, by ADR
0006's device policy), and whether the trigger fired later than the
allocation rate allowed. Then fix the cause: the trigger's headroom as a
function of the large allocation rate, the marker's QoS raised while a
cycle started by a large allocation is behind, or the allocation waiting
a bounded time for the sweep's apply before it falls back. Any policy
change is measured for energy on the phone as experiments/power did,
since the marker's QoS was chosen there for a fifth of the energy.

Done when 10 launches of `scenario=large` on each device, interleaved
with idle, count no fallback, miss no frame, and the main thread's
stopped time is no worse than the rows in `docs/modules/shells.md`; the
Mac's rows stay as they are; and the same holds for the photo-sized
scenario of part 1.

## 3. Pieces against one String

Build the one-String form of a long protocol line both ways behind a
switch (the server's reply, the client's request and the image's
`DevClient`), and measure both forms: the 2000-class image's
`class.hierarchy` and `package.selectors` round trips and the scripted
session Mac to Mac, old-space bytes allocated and marking cycles started
per 100 large replies, the main thread's stopped time while a serving
shell answers them, and the same from a device once the device
investigation has a 2000-class image served from one. Keep the cheaper
form and delete the other; if they are within noise, keep the pieces
(they exist and are tested) and say so.

## Verification

Every gate on the final code commit, outputs to files, `gates.log` with
the commit of each: a clean build with 0 warnings, `swift test` alone and
under 12 busy loops, ThreadSanitizer alone and under load, `just
ios-check`, `just arc-check`, `just golden`, `just test-release`, `just
model-check`, `just soak`, the four `just fuzz <target> 600` runs with
their "libFuzzer build: ok" lines, `just apps`, `just kernel-test`,
`just new-check`. The aligned A/B against the starting commit and the
`interpret` diff. Broken variants: the bounds check that trusts the
sentinel, the loader that trusts a length past its run, the long
primitive that never lets a stop in.

## Decision record

ADR 0003 gets a "Built (large bytes)" note with the header's meaning for
byte objects and the measured cost; ADR 0006 one with the trigger's
change, if any.
