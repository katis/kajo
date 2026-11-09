# Discoverability and instance enumeration (a follow-up of module 9c)

The owner tried the v0.1 release on 2026-11-09 and could not find how to
evaluate code: the Workspace's Cmd-D, Cmd-P and Cmd-I are bound on the
text views (`ToolWindow>>evaluateIn:with:key:`) and the Browser's Cmd-S on
its source pane, but no menu, context menu or status line names them; the
only context menu is the Browser's selectors list. The owner also asked
for Pharo's way of finding every instance of a class (`allInstances`,
`allSubInstances`), which the kernel has not: `DevTools windows` works
only because the tools keep a list.

## Part 1: the keys made visible (Smalltalk, `tools/` and `kernel/`)

1. A **Smalltalk** menu in the menu bar beside Tools (`DevTools class>>installMenu`):
   Do it (Cmd-D), Print it (Cmd-P), Inspect it (Cmd-I), Accept (Cmd-S),
   Senders of it, Implementors of it, Browse it (Cmd-B is taken: choose
   keys that do not collide with the Tools menu and the Edit menu, and
   list them in the doc). Each item acts on the focused text pane of the
   key window: the pane's own `onKey:` block runs as if the key had been
   pressed, so the menu and the key do exactly the same thing. Decide
   and state how a menu item reaches the focused pane (the tool windows
   know their panes; a view's `focus` state may need a `get` the
   wrapper lacks, which is a Swift change in `Sources/KajoApp/AppKitViews.swift`
   and the `TextView` wrapper; if the host must report the first
   responder, add the smallest such property and its test).
   Make sure a menu key equivalent does not swallow the key before the
   text view's `bindKeys:` sees it, or the other way round, such that
   the action runs exactly once (AppKit tries the key window's views
   first in `performKeyEquivalent:`, then the menu bar; measure, do not
   assume: a test in the shell's tests mode that presses Cmd-D with a
   workspace focused and counts one evaluation).
2. The same items as a **context menu** on every source and workspace
   pane (`View>>contextMenu:` exists): the Workspace, the Browser's
   source pane (Accept, Senders, Implementors, Browse), the inspector's
   and debugger's evaluation panes. Items that do not apply to a pane are
   left out, not disabled.
3. A **status-line hint** when a Workspace opens, until its first
   evaluation: "⌘D do it · ⌘P print it · ⌘I inspect it"; the Browser's
   source pane: "⌘S accept" when a method is selected and the pane
   edited (the status line already names a compile error's line).
4. A **Help menu** with "Keyboard Shortcuts" opening a read-only text
   window listing every binding of the tools (the Tools menu's, the
   Smalltalk menu's, the Browser's, the debugger's toolbar), generated
   from the menus so it cannot drift, and "Kajo on GitHub" opening
   https://github.com/katis/kajo (the host's `open` of a URL exists for
   New App…'s Xcode; if a URL open does not, add the smallest primitive
   or host op and say so).
5. The release notes template (`scripts/release.sh`'s notes) gains a
   "First steps" paragraph: open a Workspace (⌘K), type `3 + 4`, press
   ⌘P; `"…"` is a comment and `'…'` a String.

## Part 2: finding instances (VM, `Sources/KajoVM/ObjectModel/`, core tier)

A primitive `allInstancesOf:limit:` (number 167; 166 is the last) that
answers an Array of every live object whose class is the receiver, up to
`limit` elements, and `instanceCountOf:` (168) that answers the count
without allocating. Design constraints, each stated in the doc:

- It runs in a stop of the kind host inspection already takes, after the
  module 1 promote-all hook (every operation that assumes nothing young
  runs it), so it walks old space only: the entry table's used entries
  (`OldMap`'s bit, or the free list excluded) with the class read from
  the header. Deferred-free and swept-but-pending entries are not
  instances (the sweep-stop doc's one-owner table lists every entry state;
  agree with it). Large objects count once (their head).
- Two passes inside one stop (count, then fill) or one pass into a Swift
  buffer handed over after: whichever allocates the Array *outside* the
  stop (an allocation inside a stop is forbidden to the main worker's
  own stop? state the rule and the reason) — the result Array is a
  pending root until it is answered (module 10's lesson: an object held
  only by the stop that allocated it is unrooted the moment its worker
  parks). An Array past 4095 slots is a large object; `limit` defaults
  to 100 000 in the kernel and the primitive refuses above 16 777 215.
- Instances of `SmallInteger`, `SmallFloat`, `Character`, `UndefinedObject`,
  `True`, `False` answer an empty Array (immediates) and the booleans and
  nil their single instance; `Behavior>>allInstances` documents it.
- The stop's duration over the development image (about 1.25 million
  entries at the high-water mark, the 2000-class image more) measured and
  recorded as its stop kind on the run line; if it exceeds 5 ms on the
  Mac, the walk polls between 65 536-entry chunks like the marker and the
  Array is filled across stops with the one-owner argument for an entry
  that changes between chunks (state which you built and why).
- Kernel: `Behavior>>allInstances`, `allInstances:` (limit),
  `allSubInstances` (the class and every subclass, by `withAllSubclasses`,
  one walk with a class set, not one walk per class: the primitive takes
  an Array of classes), `instanceCount`, `Object class>>someInstance`
  is not needed. `kernel/ReflectionTest` (or beside `ObjectTest`): a
  fresh instance appears, a dropped one disappears after
  `Smalltalk garbageCollect`, the limit holds, a class with no instances
  answers `#()`, the immediates' cases, `allSubInstances` includes a
  subclass's instance, and the count equals the Array's size under the
  limit.
- `ExtremeIntegerTests` gets the new primitives (minVal, maxVal, -1, 0,
  count + 1 as limits); the random programs need no new step.
- Tools: an inspector on a class gets an "Instances" pane or the
  Smalltalk menu an "Instances of it" item (recommended: the menu item,
  opening an inspector on `allInstances: 1000`; the inspector shows the
  count in its title when the limit cut it off).

## Bar

- Every key of the tools appears in a menu, and the menu item and the
  key do the same thing exactly once (the tests-mode test above).
- Right-click on any workspace or source pane shows the items that
  apply; the Workspace shows the hint; Help > Keyboard Shortcuts lists
  every binding and is generated from the menus (a test asserts every
  `bindKeys:` key of the tools is in it).
- `Behavior>>allInstances` and `allSubInstances` work on the development
  image for `ToolWindow` (equals `DevTools windows` size),
  `Class` (the image's class count), `String` under a limit, and
  `SmallInteger` (`#()`); the kernel tests pass (211 plus the new ones)
  headless, in the Mac shell's tests mode and on the iPhone.
- The stop's time for `Object allInstances: 1` (the walk without the
  fill) and `String allInstances: 100000` on the development image, and
  on the 2000-class image, recorded; no frame missed in the Mac shell
  while a Workspace evaluates `String allInstances: 100000` ten times
  (`mode=scenario` is not the tool; use the devsession or a scripted
  Workspace step and the shell's frame account, say how).
- `interpret` unchanged instruction for instruction (`just arc-check`,
  the disassembly diff), the aligned A/B within noise, `just check` on
  the final code commit: the core tier (the new primitives live in
  `ObjectModel/`), every gate; the Mac matrix and the iPhone rows run.
- Nothing in the kernel's existing tests changes; the round trip
  byte-identical (`canonical-tonel.sh --check`).

## Open questions for the owner (build the recommended option, list them)

1. Should `pointersTo:` (every object referencing a given one, Pharo's
   `pointersTo`) be built with the same walk? Recommended: not now; it
   is the same stop with a slot scan per object (the marker's work in a
   stop), a module of its own if wanted.
2. Should the Smalltalk menu's items also appear in the Edit menu, as
   Pharo's text menus do? Recommended: no, one place (Smalltalk) plus the
   context menu.
3. Should `allInstances` default to a limit (100 000) or to no limit as
   Pharo's? Recommended: a limit, with `allInstances:` for more; a
   development image's `Object allInstances` is millions of objects in
   one Array and a stop a frame long.
