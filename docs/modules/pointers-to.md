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
