# `pointersTo:` (a follow-up of the discoverability module)

The owner asked for it on 2026-11-09 when `allInstances` was briefed ("I
want `pointersTo:`. Can be done after the others"): every object that
references a given one, Pharo's `anObject pointersTo`, as the second
reflection tool after `allInstances`. The discoverability follow-up
(`docs/modules/discoverability.md`, "Finding instances") built the walk
this one extends: one stop of the world of kind `instances` after module
1's promote-all hook, a walk of the old map's used entries, the answer
Array allocated in the stop through the object memory and rooted by the
answer. This module adds a slot scan per visited object and the kernel
and tool surface for it. The VM change is one or two primitives and what
they need in the object memory, nothing else; `interpret` identical
instruction for instruction.

## Part 1: the primitives (VM, `Sources/KajoVM/ObjectModel/`, core tier)

A primitive `pointersTo:limit:` (number 169; 168 is the last) that
answers an Array of every object in the heap with at least one slot
holding the argument, at most `limit` of them (0 to 16 777 215, the count
field's limit), in entry-table order, and `pointerCountTo:` (170) that
answers how many such objects there are without allocating. Design
constraints, each stated in the doc as built:

- The same stop as 167 and 168 (`StopKind.instances`, or a kind of its
  own if its time differs enough to want its own row: say which), after
  the promote-all hook with the stop's roots; after the hook nothing is
  young, so the PLAN row's "remembered young holders" are simply old
  objects by then and need no second source. The walk is
  `ObjectMemory.walkInstances`'s loop over the old map with a slot scan
  in place of the class check: every pointer object's slots (named and
  indexable), a large object's slots across its run (the marker's
  `walkRuns`), byte objects skipped by their format, the slot compared
  raw against the argument's oop (so an immediate argument works too: `3
  pointersTo` finds every Array holding 3, which Pharo allows; it is
  slow and that is fine). Weak slots count (a WeakArray holding the
  object is a holder; open question 1). An object's class pointer is not
  a slot and does not count (instances are `allInstances`' business);
  the method's literal frame is slots, so a CompiledMethod whose literal
  is the object is a holder, as in Pharo. The answer Array is skipped as
  167 skips it, and the argument itself (a self-reference is still a
  holder: `a at: 1 put: a` lists `a`; only the answer is excluded).
- Process stacks are not in the heap (module 3's Process-owned stacks)
  and are not scanned: an object held only by a frame's temporary or an
  interpreter register has no heap holder and answers `#()`. Saved
  Process stacks in the image (8c's Array chunks) are heap objects whose
  words are copied verbatim, so a saved frame's reference *is* found as a
  slot of its chunk; say so and that the two differ (open question 2).
- The Array: as 167 does it (count, allocate in the stop through the
  object memory, fill; a second exact Array if the allocation collected),
  rooted by the answer; state the same rule and reason.
- **The stop's time is the question this module answers before anything
  else.** `allInstances` read one header per entry; this reads every slot
  of every old object, the marker's whole tracing work in one stop. Part
  1a: build it unbounded, measure on the development image and on the
  2000-class image (`KAJO_SHELL_CLASSES`, `kajo run` with the generated
  image), with and without 1.2 million garbage objects, for an argument
  held by one object, by many (`nil` is held by most slots: `nil
  pointersTo: 1` is the walk that finds at once; `nil pointerCountTo`
  visits everything and is the worst case) and by none. Record the words
  scanned and the nanoseconds per word. Part 1b, decided from 1a: if the
  worst-case stop on the development image exceeds 5 ms on the Mac (one
  frame at 120 Hz is 8.3 ms; the main thread's own turn needs the rest),
  the walk polls between chunks of entries like the marker, each chunk
  its own stop after the hook, the holders found so far in an Array that
  is a pending root between stops (module 10's lesson), and the doc
  states the one-owner argument for an entry that changes between chunks
  (the world runs between them: a holder that stores or drops the
  reference between chunks is missed or stale, which is Pharo's rule too
  and is said in `Object>>pointersTo`'s comment) and what the relocator
  may do between chunks (the hook abandons a cycle at each chunk; say
  what a cycle started between two chunks costs). If 1a stays under 5 ms,
  build nothing of 1b, say so with the numbers, and leave the chunk
  design as a paragraph. Either way the slot scan inside a stop reads
  nothing through a hazard slot or pin: the world is stopped.
- Kernel: `Object>>pointersTo` (no default limit; the owner's answer of 2026-11-09, the primitive's 16 777 215 the only bound),
  `pointersTo:`, `pointerCount`; category `reflection` or beside
  `allInstances`' category; `pointersTo:` checks the limit before the
  primitive and names the reason. `kernel/ReflectionTest`: an object
  held by exactly one Array answers that Array; a dropped reference
  disappears after `Smalltalk garbageCollect`; the holder of a method
  literal is the CompiledMethod; a holder past 4095 slots (a large
  Array, the object at its last slot) is found; a weak holder is found;
  the limit holds; `3 pointersTo: 1` is non-empty; an object held only by
  a temporary answers `#()` (the frame rule); the count equals the
  Array's size under the limit; the answer is not its own element.
- `ExtremeIntegerTests` gets 169 (minVal, maxVal, -1, 0, count + 1 as the
  limit) and 170 (each as the argument); `InstancePrimitivesTests` gains
  the Swift side (young holders promoted and found in the stop, a large
  holder, a weak holder, a marking cycle abandoned and a pending sweep
  applied with no verifier failure, the answer not its own element). The
  random programs need no new step.

## Part 2: the tools (Smalltalk, `tools/`)

- The Smalltalk menu gains "Objects pointing to it" with a key that is
  free in every menu (recommended ⇧⌘O; Help > Keyboard Shortcuts lists
  it by construction and its test asserts it), acting as "Instances of
  it" does: the Workspace evaluates the selection or the line, sends
  `pointerCount` and `pointersTo: DevTools instancesLimit` to the result,
  and opens an inspector whose title says "N objects pointing to
  <printString>" (or "L of N" when the limit cut it off), with the status
  line showing the count. On a source pane it acts on the selection
  evaluated as in the Workspace (the brief's "Instances of it is not
  offered on source panes" stays; this item is offered where Instances
  of it is).
- The Inspector's context menu gains the same item on the inspected
  object and on the selected field's value, opening a new inspector.
- `DiscoverabilityTest` gains the item (in the menu, in the context menus
  of the panes where it applies, the key in the Help list); `tools/`'s
  tests of the inspector cover the new item against `FakeDevClient`.
- The release notes' "First steps" mention it beside Instances of it
  (`scripts/release.sh`).

## Bar

- `Object>>pointersTo` on the development image answers, for a fresh
  object stored in one Array, exactly that Array; `ToolWindow` instances'
  holders include `DevTools`' windows collection; `nil pointerCountTo`
  (the worst case) finishes; the kernel tests pass (218 plus the new
  ones) headless, in the Mac shell's tests mode and on the iPhone.
- The stop's time recorded as in part 1a (the one-holder, the `nil`
  count and the none cases, both images, with and without garbage, words
  scanned and ns per word), and the chunking decision made from it with
  the numbers in the doc.
- No frame missed in the Mac shell while a Workspace evaluates
  `(x pointersTo: 100000) size` ten times for an `x` held by a few
  objects, and the frames counted while `nil pointerCount` runs once,
  through the discoverability follow-up's `mode=devsession
  session=instances` extended or a `session=pointers` of its own (say
  which; each evaluation a step whose frames are counted).
- "Objects pointing to it" in the Smalltalk menu and the Inspector's
  context menu, opening an inspector with the count in its title;
  `DiscoverabilityTest` and the tools' tests pass; the Help list has the
  key.
- `interpret` unchanged instruction for instruction (`just arc-check`,
  the disassembly diff), the aligned A/B against the starting commit
  within noise, the round trip byte-identical (`canonical-tonel.sh
  --check` on `kernel/` and `tools/`), `just check` on the final code
  commit: the core tier (the primitives live in `ObjectModel/`), every
  gate; the Mac matrix and the iPhone rows run.

## Open questions for the owner (build the recommended option, list them)

1. Should a weak holder count as pointing to the object? Recommended:
   yes, listed like any other (it is a reference the developer may want
   to find, and the walk compares raw oops without reading formats); a
   later inspector could mark weak holders.
2. Should Process stacks be scanned, so an object held only by a running
   frame's temporary shows that frame (as a Context) among its holders?
   Recommended: not now; the frames are not heap objects, materializing
   Contexts for every frame of every Process in a stop is a design of
   its own, and the answer `#()` with the rule in `pointersTo`'s comment
   is honest. Saved stacks in the image are found as slots of their
   chunks, which the doc says.
3. Should an immediate argument be refused (`3 pointersTo` is every Array
   holding 3 and scans the whole heap for a number)? Recommended: allow
   it, as Pharo does; the limit bounds the answer and the stop's time is
   the same walk as `nil pointerCount`, measured in part 1a.

## As built (2026-11-09)

Commits 8e28e6d (the primitives), 8bd770d (the kernel), 50157f3 (the walk
from part 1a's numbers), 0d7f5c8 (the tools and the release notes),
24baed0 (the measurement session), e8dab54 (a clean build's warning),
d326190 (no default limit, the owner's answer of 2026-11-09) and the doc
commit. The open questions are built as recommended, as the owner
answered them the same day.

### The primitives: 169 and 170

`Smalltalk primPointersTo: anObject limit: n` (169) and `Smalltalk
primPointerCountTo: anObject` (170), `Sources/KajoVM/ObjectModel/InstancePrimitives.swift`
with the walk in `Sources/KajoVM/ObjectMemory/Instances.swift`
(`walkPointers`). `anObject` is anything, an immediate included; `n` a
SmallInteger from 0 to 16 777 215; anything else fails and the kernel
names the reason. Against the constraints:

- **The stop.** The same stop as 167 and 168: `StopKind.instances`, in it
  module 1's promote-all hook with the stop's roots, then the walk of the
  old map's used entries. Not a kind of its own: the measured stops are
  of the same order as 167's (below), and a kind of their own would only
  split one row of `stopsByKind`. Each stop record now carries `words`,
  the slots its walk compared (0 for every other stop; `noteStopWork`,
  printed as `"words"` on the `gc` event): the measurement of part 1a
  needed it (a deviation, below). After the hook nothing is young, so the
  PLAN row's "remembered young holders" are old objects and need no
  second source; a young holder is promoted and found
  (`PointersToTests.youngHoldersArePromotedAndFoundInAStopOfKindInstances`).
- **Which slots count.** Every slot of every old pointer object, named and
  indexed alike, the header's count of them, compared raw with the
  argument's oop: nothing is dereferenced, so an immediate argument works
  (`3 pointersTo` lists every object holding 3). Byte objects, long ones
  included, are skipped by the header's bytes bit. The class is in the
  header, not a slot, and never counts. A weak object's weak slots and an
  ephemeron's slots count as any other (open question 1): the walk does
  not read the class format at all.
- **Large objects.** One entry whose body is its run of contiguous blocks,
  so its slots are indexed from its body offset exactly as the marker's
  `traceChunk` indexes them (there is no `walkRuns` function; the run is
  contiguous). In a stop nothing needs splitting; a holder at slot 10 000
  of a 10 000-slot Array is found (`ReflectionTest>>testALargeHolderIsFound`,
  `aLargeHolderAtItsLastSlotAndAWeakHolderAreFound` at 5000).
- **Methods.** A CompiledMethod's literal frame is an Array of its own
  (slot `MethodLayout.literals`), not the method's slots as in Pharo. The
  developer asks which method uses the object, so a method whose literal
  frame holds the argument is the holder and that literal frame is not
  listed: the walk reads a method's frame where it meets the method, and
  because a frame's entry may come before its method's, the first
  read-only Array it finds holding the argument (every literal frame is
  read-only, a rule the loader checks, and few other holders are) makes
  it note, in one pass over the methods, every frame holding the argument,
  skipped from then on. A block method is a literal of its outer method,
  so the outer method stands for it. The method's own slots (selector,
  class, bytecodes) are compared as any object's.
- **Excluded.** The answer Array, as 167 skips it. The argument itself is
  not excluded: `a at: 1 put: a` lists `a`.
- **Process stacks.** Not in the heap (module 3's Process-owned stacks)
  and not read: an object held only by a frame's temporary, an argument or
  an interpreter register has no heap holder and answers `#()`
  (`ReflectionTest>>testAnObjectHeldOnlyByATemporaryAnswersNothing`,
  `anObjectHeldOnlyByAFrameHasNoHolder`). A BlockClosure that copied the
  object is a heap object and is a holder; a Context materialized for the
  debugger is one too. Saved Process stacks in an image (8c's Array
  chunks, words copied verbatim) are heap Arrays, so a saved frame's
  reference *is* found, as a slot of its chunk: the two differ, which is
  open question 2.
- **The loads.** Inside the stop the slots are read with plain loads, eight
  at a time as one vector compare (`SIMD8<UInt64>`, `cmeq` in the
  disassembly), through no hazard slot and no pin: the hook abandoned any
  marking cycle so no relocation runs, every mutator and the marker are
  parked, and the stop's lock orders their earlier stores before the
  walk.
- **The Array.** Allocated in the stop through the object memory, as 167's
  (the rule and its reason in `discoverability.md` hold word for word: no
  worker allocates through the mutator's path inside a stop, which may
  itself need a stop or wait for the marker; nothing is young and no
  cycle runs after the hook, so the Array needs no barrier, remembered
  word or snapshot bit), rooted by the primitive's answer with no poll
  and no allocation between the stop's release and the interpreter's
  push. Unlike 167 the walk runs once: the holders go into a host buffer,
  the Array is allocated and filled from it. If that allocation collected
  (old space full; `om.counters.collections` moved), what it freed may be
  in the buffer, so the Array is filled by a second walk instead and, when
  that finds fewer, the answer is a second Array of exactly what was found
  (`whenTheAnswersAllocationCollectsTheAnswerIsExact` under
  `collectAtEveryAllocation`; it fails with the buffer trusted after a
  collection, run by hand).
- **Release images.** Both work in a release image: they read, as `slotAt:`
  and 167 do, and change nothing.

### Part 1a: the stop's time

`kajo test` (release build, 4 workers) on the development image (kernel,
tools, the shell's Smalltalk, a measuring test class: 210 classes, 2576
methods) and on the same with the 1806 generated classes (2016 classes,
22 442 methods), ten stops a row, the per-stop `gc` events with their
`words`; three phases in one run: as built, after a churn of 1.2 million
`Object new` left as garbage (with the OrderedCollection's grown Arrays,
4.2 million garbage slots), and after `Smalltalk garbageCollect` (the
high-water mark stays). A: `o pointersTo` for `o` held by one Array, B:
`o pointerCount`, C: `Object new pointerCount` (held by none: the whole
walk), D: `nil pointerCount` (the worst case named by the brief), E: `nil
pointersTo: 1` (finds at once). `words` is the slots compared: an object
holding the argument stops being compared at the first hit, so `nil`'s
walk compares fewer words than C's. The final code, ms
(`stops/table.txt`; runs 2 and 3 within 0.2 ms of it):

| Walk | dev p50 | dev max | dev words | ns/word | 2000 p50 | 2000 max | 2000 words | ns/word |
|---|---|---|---|---|---|---|---|---|
| A one holder, list | 0.170 | 0.334 | 134 330 | 1.27 | 0.875 | 1.461 | 739 032 | 1.18 |
| B one holder, count | 0.169 | 0.195 | 134 335 | 1.26 | 0.818 | 0.866 | 739 037 | 1.11 |
| C none | 0.166 | 0.168 | 134 335 | 1.24 | 0.800 | 0.824 | 739 037 | 1.08 |
| D `nil pointerCount` | 0.272 | 0.305 | 102 659 | 2.65 | 1.126 | 1.183 | 504 392 | 2.23 |
| E `nil pointersTo: 1` | 0.004 | 0.004 | 7 | | 0.022 | 0.025 | 15 | |
| garbage: A | 2.665 | 4.668 | 4 327 634 | 0.62 | 3.465 | 5.893 | 4 932 336 | 0.70 |
| garbage: B | 2.556 | 2.624 | 4 327 639 | 0.59 | 3.413 | 3.502 | 4 932 341 | 0.69 |
| garbage: C | 2.526 | 2.554 | 4 327 639 | 0.58 | 3.402 | 3.417 | 4 932 341 | 0.69 |
| garbage: D | 3.234 | 3.344 | 102 695 | | 3.960 | 4.452 | 504 428 | |
| garbage: E | 0.004 | 0.007 | 7 | | 0.022 | 0.028 | 15 | |
| collected: A | 0.167 | 0.223 | 133 306 | 1.25 | 0.779 | 0.932 | 716 504 | 1.09 |
| collected: B | 0.174 | 0.207 | 133 311 | 1.31 | 0.774 | 0.803 | 716 509 | 1.08 |
| collected: C | 0.161 | 0.165 | 133 311 | 1.21 | 0.774 | 0.781 | 716 509 | 1.08 |
| collected: D | 0.288 | 0.312 | 102 658 | | 1.079 | 1.118 | 504 385 | |
| collected: E | 0.003 | 0.004 | 7 | | 0.022 | 0.023 | 15 | |

`nil` has 3160 holders on the development image and 10 363 on the
2000-class one. ns per word is the stop over the words; where few words
are compared (D, E) the stop is the entries visited, not the words (D
with garbage: 1.2 million zero-slot entries at about 2.5 ns each). Every
garbage row's maximum is its first stop, whose promote-all moves the 1.2
million young objects (about 2 ms, as in 167's measurement).

**The first build was over the bound**, and the walk was changed before
the decision (`stops/steps.txt`, `stops/first/`). As first built it
walked twice in the stop for 169 (count, then fill, as 167), compared one
slot at a time with relaxed atomic loads, and noted the methods' literal
frames in an eager pass over every entry before the walk. On the
development image with garbage: A 10.09 ms p50 and 12.36 max, B and C 5.0,
D 3.3; on the 2000-class image A 11.74 and 14.93. Then, each step
measured: one walk into a host buffer (A 5.53 and 7.60), eight slots per
vector compare (A 4.25 and 6.17, B 4.17), and the frames' pass only on the
first read-only Array holding the argument (the table: A 2.67 and 4.67,
B 2.56). No step changed what is found; the Swift and kernel tests ran
after each.

**Chunking: not built.** The worst stop on the development image, the
brief's bound, is 4.67 ms (4.53 and 4.56 in the two repeat runs): the
first stop after 1.2 million garbage objects, its promote-all included;
every other is under 3.4 ms, and every stop without that garbage under
0.34 ms. That is under 5 ms, so the walk does not poll and no holder is
collected across stops. The 2000-class image with the same garbage is
over it at its first stop (5.89, 6.25 and 6.38 ms in three runs, the
promote-all included; 3.5 to 4.6 ms for every later walk), which the
brief's bound does not cover; it is said here and under not done. The
cost scales with the heap: about 0.6 to 1.3 ns per slot word and 1 to 2.5
ns per entry, so a heap of 10 million old slot words is a stop of about
6 to 13 ms.

The chunk design, not built: the walk polls between chunks of 65 536
entries like the marker, each chunk a stop of its own after the hook; the
holders found so far are in an Array that is a pending root between the
stops (module 10's lesson: an object held only by the stop that made it
is unrooted the moment its worker parks), grown or copied at the end.
Between two chunks the world runs, so an entry's one owner changes under
the walk: a holder that stores the argument into an entry already walked
is missed, one that drops it after its chunk is listed stale, and an
object freed and its entry reused between chunks is listed for what it
held at its chunk (Pharo's rule; `Object>>pointersTo`'s comment says the
world runs between two sends already). The hook at each chunk abandons a
marking cycle and finishes a pending sweep, and a relocation pass is cut
off by it, so a cycle started between two chunks is abandoned at the next
one: a walk of N chunks can cost the collector N - 1 abandoned initial
marks, and a long one under allocation would starve old-space collection
unless it held the trigger off until its last chunk. Nothing of that is
needed at the measured stops.

### The kernel

`Object>>pointersTo` (no default limit: every holder, up to the largest
Array, 16 777 215; d326190), `pointersTo:` (the limit checked
before the primitive and named: "the limit of pointersTo: is an Integer
from 0 to 16777215, not …"), `pointerCount`, category `reflection`; the
comment of `pointersTo` warns that `nil pointersTo` or `3 pointersTo` can
be a long Array made in one stop and states the rules (every slot, weak ones too;
the class is not a slot; a method stands for its literal frame; garbage
until a collection; Process stacks not searched and a temporary is no
holder; the world runs between two sends; an immediate works; a
self-reference is listed, the answer never). `Smalltalk
primPointersTo:limit:` and `primPointerCountTo:` beside 167's.
`ReflectionTest` gains ten tests (category `pointers`): an object held by
exactly one Array answers that Array; a dropped reference disappears
after `Smalltalk garbageCollect`; the holder of a method literal is the
method and not its literal frame; a holder past 4095 slots (the object at
slot 10 000) is found; a WeakArray holder is found; the limit holds and
refuses -1, 16 777 216 and nil, and `pointersTo` answers as many as
`pointersTo: 16777215`; `3 pointersTo: 1` is non-empty and finds
an Array holding 3; an object held only by a temporary answers `#()`; the
count equals the Array's size under the limit; the answer is not its own
element and a self-reference is listed. The kernel tests: 228 of 228
headless, 228 of 228 in the Mac shell's tests mode, 228 of 228 on the
iPhone 13 Pro (`iphone/`, thermal nominal, 5.2 s).

Swift: `Tests/KajoVMTests/ObjectModel/PointersToTests.swift`, nine tests
(young holders promoted and found in two stops of kind `instances` with
their words recorded, the limit; a large holder at its last slot and a
weak holder; an immediate, a self-reference, and `nil`'s answer not its
own element with the count equal to the unlimited answer's size; a
method standing for its literal frame; a frame's temporary has no holder;
garbage until a collection; a marking cycle abandoned and a pending sweep
applied with no verifier failure; bad limits refused; the answer's
allocation collecting); `ExtremeIntegerTests` calls 169 with minVal,
maxVal, -1, 0 and 1 as the limit and as the argument, and 170 with each as
its argument.

### The tools

The Smalltalk menu gains **Objects pointing to it, ⇧⌘O** (`cmd-shift-o`,
id 19, after Instances of it): no other item of the Tools, Smalltalk,
Edit, app or File menus takes it. It is offered exactly where Instances of
it is (the Workspace and the inspector's and debugger's evaluation panes,
their context menus included; not on source panes), and acts as it does
(`DevTools pointersTo:with:`): the selection or the line is evaluated where
the pane evaluates as `(it) pointerCount`, then `(it) pointersTo: 1000`
(`DevTools instancesLimit`), then `(it) printString`, and an inspector
opens on the Array titled `Array #(…) (L of N objects pointing to P)`, or
`(N objects pointing to P)` under the limit, one object singular, with P
the printString cut at 40 characters; the pane's status line says the
same. The count and the list are asked for first: every evaluation's
answer gets a handle in the development session, whose table would hold
the object from then on. Help > Keyboard Shortcuts lists it by
construction (generated from `smalltalkItems` and `paneKeys`).

The Inspector's slots table gets a context menu (`InspectorWindow
slotsMenuItems`): **Objects pointing to it** on the inspected object
(`self` through the inspector's workspace, whose receiver is its handle)
and **Objects pointing to the slot's value** on the selected row (through
the slot's handle, or for a value without one, nil, a Boolean, a
SmallInteger or a Character, its printString evaluated), each opening a
new inspector. An object an inspector shows is held by the session's
handle table, which is therefore among its holders.

Tests: `DiscoverabilityTest` (8): the item in each pane's context menu,
its key in the Help text and in no other item, the Workspace's three
requests and the inspector's title and status (`Array #(an Array) (1000 of
1532 objects pointing to it's x)`); `InspectorModelTest` (3): the slots
menu on the object, on a slot with a handle and on one without, against
`FakeDevClient`. The development image's tests 267 of 267 (228 kernel,
39 tools). The release notes' "First steps" name ⇧⌘I and ⇧⌘O.

### The bar's measurements

**On the development image** (the shell's `mode=devsession
session=pointers`, new, `DevSessionBench startPointers:`; the first step
evaluated through the tools' client, after `Smalltalk garbageCollect`):
`#(1 true 3 true 14685)`: a fresh object stored in one Array answers one
holder and it is that Array; the first tool window has 3 holders and they
include the Array of `DevTools windows`; `nil pointerCount` finishes
(14 685 holders in the shell's image).

**Frames** (`frames/`, the Mac mini's 120 Hz display, thermal nominal,
two launches each on the development image and the 2000-class one): a
Workspace evaluates `(DevTools windows first pointersTo: 100000) size` (a
window has 3 holders) ten times by its Do it, then, in the same window so
no window opens in the step, `nil pointerCount` once; each evaluation is
a step timed to its answer whose frames the shell counts
(`steps_ms_missed`). 0 frames missed in all 40 `pointersTo:` steps (5.6 to
17.2 ms each, the first of a launch the longest) and in all 4 `nil
pointerCount` steps (5.5 to 7.1 ms). The launches' whole windows missed
18, 20, 19 and 20 frames, none in an evaluation step: the windows opening
and, once, the check step on the 2000-class image (3 frames, 47 ms: its
`Smalltalk garbageCollect` is a full collection of a 37 MB image, not the
walk). A first version of the session evaluated `nil pointerCount` in a
window of its own (`frames/first/`): that step missed 1 frame in two of
four launches, where the window opened, with no stopped turn
(`max_turn_stop_ms=0.0`); the session was reordered to measure the walk,
not AppKit's first display.

**`interpret` and the A/B.** `just arc-check` passes (no retain or
release on the checked paths, the dispatch loop one jump table;
`arc-check.txt`). The new primitives are cases of `instancePrimitive`,
which `primitive(_:_:_:)` calls out of line (its case range 167...170);
`interpret` in `Dispatch.o` of the aligned `-enable-testing` builds of
54bd2a6 and e8dab54 is identical, 1817 lines each with an empty diff,
addresses included (`interpret.diff`). `scripts/ab.sh 54bd2a6` (5
interleaved runs, aligned builds, checksums equal everywhere; `ab/`):
0.993 to 1.003 at 1 worker with instruction ratios 1.000 (st-closures
0.986, cycles 0.988: a Smalltalk kernel built from the changed kernel
classes), 0.970 to 1.031 at 8 workers with overlapping ranges and
instruction ratios 0.997 to 1.001, as earlier modules' 8-worker spread.
The VM change adds 9 lines with `unsafe` (the vector scan's three, the
stop record's `words`); a clean build and `just ios-check` have no
warning.

**The round trip.** `scripts/canonical-tonel.sh --check` lists no file on
the kernel commit, the tools commit and e8dab54 (`tonel-roundtrip.txt`;
the Tonel files were rewritten into the image's form after each hand
edit).

### `just check`

`just check 54bd2a6` on d326190 picked the core tier (chosen by
`Interpreter/Primitives.swift`, `ObjectMemory/Instances.swift`,
`ObjectModel/InstancePrimitives.swift`, `Workers/Safepoint.swift` and
`Workers/VMState.swift`; 25 files in the diff), toolchain swift.org 6.4.2
first on PATH, and every gate passed in 12 253 s. A first run on e8dab54
was stopped in its third gate when the owner's no-default-limit answer
arrived, so the gates ran on the final code. Its `gates.log`:

```
2026-11-09 14:46:17 d326190 end clean-build rc=0 26s
2026-11-09 14:53:19 d326190 end swift-test rc=0 422s
2026-11-09 15:01:10 d326190 end swift-test-load rc=0 471s
2026-11-09 15:47:05 d326190 end tsan rc=0 2755s
2026-11-09 16:44:56 d326190 end tsan-load rc=0 3471s
2026-11-09 16:45:10 d326190 end ios-check rc=0 14s
2026-11-09 16:45:17 d326190 end arc-check rc=0 7s
2026-11-09 16:46:26 d326190 end golden rc=0 69s
2026-11-09 16:48:02 d326190 end test-release rc=0 96s
2026-11-09 16:48:23 d326190 end model-check rc=0 21s
2026-11-09 16:49:33 d326190 end soak rc=0 70s
2026-11-09 17:00:13 d326190 end fuzz-kasm rc=0 640s
2026-11-09 17:10:17 d326190 end fuzz-snapshot rc=0 604s
2026-11-09 17:20:28 d326190 end fuzz-syntax rc=0 611s
2026-11-09 17:30:36 d326190 end fuzz-protocol rc=0 608s
2026-11-09 17:32:34 d326190 end apps rc=0 118s
2026-11-09 17:33:47 d326190 end kernel-test rc=0 73s
2026-11-09 17:37:49 d326190 end new-check rc=0 242s
2026-11-09 17:43:08 d326190 end ab rc=0 319s
2026-11-09 17:56:02 d326190 end matrix-mac rc=0 774s
2026-11-09 18:10:04 d326190 end matrix-iphone rc=0 842s
```

408 + 121 Swift tests in every test gate, ThreadSanitizer 0 reports alone
and under load, 228 kernel tests, the four fuzzers with "libFuzzer build:
ok" at 2.24 (kasm), 3.36 (snapshot), 0.82 (syntax) and 1.82 (protocol)
million runs in 601 s, the gate's own A/B 0.986 to 1.004 at 1 worker with
instruction ratios 1.000 and 0.941 to 1.075 at 8 with instruction ratios
0.996 to 1.002 (fib, sends and st-ivars at 8 workers 1.066 to 1.075 with
overlapping ranges, where the standalone A/B above read 1.005 to 1.031;
the 8-worker spread of earlier modules). The Mac matrix (warm-up 0 of
1200): every row but two at 0 frames missed and 0 fallbacks; the ring
under `young=stw` at 7 workers 170, 184 and 168 frames behind 8, 9 and 8
counted soft-limit fallbacks (compacting full collections of 200 to 211
ms, the oracle row's known cost) and the hog with the budget off 1192 to
1193 by design. The iPhone matrix at 5 workers (warm-up 0 of 1200, built
and signed in 12 s with no prompt): 0 fallbacks, the ring under
`young=stw` 5, 4 and 4 frames behind 13.8 to 20.2 ms scavenges as
before, the hog 1192 by design. The core tier does not list the tools'
tests or the Mac shell's tests mode; both ran on d326190 before it (267 of
267 and 228 of 228).

### Deviations

- No default limit, the owner's answer to discoverability's question 3
  and pointers-to's default, 2026-11-09 (d326190): `Object>>pointersTo`,
  `Behavior>>allInstances` and `allSubInstances` answer every holder or
  instance up to the largest Array (16 777 215); `pointersTo:`,
  `allInstances:` and `allSubInstances:` take an explicit limit; the
  comments keep the stop-a-frame-long warning as a warning;
  `ReflectionTest`'s two limit tests use the explicit forms and assert
  that the default answers as many as the largest limit. The tools still
  show a bounded list (`DevTools instancesLimit`, 1000, unchanged). The
  stop and frame measurements above ran before it with explicit limits
  or on one-holder objects, so it changes none of them; the kernel tests
  ran again after it: 228 of 228 headless, in the Mac shell's tests mode
  and on the iPhone (`iphone/final/`), the development image's 267 of 267.

- The first build was changed before the chunking decision: part 1a's
  numbers for it put the development image's worst stop at 12.4 ms, and
  three changes to the unbounded walk (one walk, a vector compare, the
  frames' pass only when needed) brought it to 4.7 ms. The brief asked
  for the unbounded walk to be measured and chunking decided from it; the
  walk measured is still unbounded, and every step's numbers are recorded.
- A CompiledMethod's literal frame is a separate Array in Kajo, so "the
  method's literal frame is slots" needed a rule: the method is listed
  for its frame and the frame is not.
- The stop record carries `words` and the `gc` event prints it: the brief
  asked for the words scanned per stop, which no counter gave. Two lines
  in `Workers/` (the record and the safepoint state, set under the
  safepoint lock by `noteStopWork`) and one in `Headless.swift`.
- 169 answers the holders found by one walk into a host buffer, not by
  167's two walks; the second walk runs only when the answer's allocation
  collected.
- The measurement session is `session=pointers` of its own, not
  `session=instances` extended, and it evaluates `nil pointerCount` after
  the ten `pointersTo:` steps in the same window (a first version opened a
  window for it and counted AppKit's first display).
- The Inspector's context menu is on its slots table and has two items,
  Objects pointing to it (the object) and Objects pointing to the slot's
  value, rather than one item twice.

### Not done

- Chunked walks: not needed for the development image (4.7 ms); the
  2000-class image's first stop after 1.2 million garbage objects is 5.9
  to 6.4 ms with its promote-all, and a heap of about 10 million slot
  words would put every walk over a frame.
- The session's handle table is listed among the holders of any object a
  tool has a handle to (an inspected object, an earlier evaluation's
  answer); the tools do not filter it out or mark it.
- Weak holders are not marked as weak in the inspector (open question 1).
- Process stacks are not searched (open question 2).
- UIKit has no menus, so neither the Smalltalk menu's item nor the slots
  table's context menu exists there; ⇧⌘O works on the panes with a
  hardware keyboard.
- The iPad.

### Open questions for the owner (built as recommended)

1. A weak holder counts? Built: yes, listed like any other; the walk
   compares raw words and never reads a class format. A WeakArray holding
   the object is found (`testAWeakHolderIsFound`).
2. Process stacks scanned? Built: not now. An object held only by a
   running frame answers `#()`, and `pointersTo`'s comment says so; a
   saved stack in an image is found as a slot of its chunk.
3. An immediate argument refused? Built: allowed, as Pharo does. `3
   pointersTo` is a whole walk like any other argument's, between the
   none row and `nil pointerCount` in part 1a (0.17 to 0.27 ms on the
   development image, 0.8 to 1.1 ms on the 2000-class one, 2.5 to 4.0 with
   1.2 million garbage objects), and the limit bounds the answer.
