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

## As built (2026-11-09)

Commits 507d7ea (the primitives), e093321 (the kernel's reflection),
a602032 (the text view, the hosts and the one-key test), dd684ec (the
tools and the release notes), 32c0a44 (the measurement session) and the
doc commit. The open questions are built as recommended.

### The tools: menus, keys, context menus, hints

**The menus.** `DevTools installMenu` now installs three menus from three
item lists (`toolsItems`, `smalltalkItems`, `helpItems`: id, title, key),
and every key and title the tools show comes from those lists:

| Menu | Item | Key |
|---|---|---|
| Tools | Browser, Workspace, Test Runner, Transcript, Targets | ⌘B, ⌘K, ⌘U, ⌘J, ⇧⌘T (unchanged) |
| Smalltalk | Do it, Print it, Inspect it | ⌘D, ⌘P, ⌘I |
| Smalltalk | Accept | ⌘S |
| Smalltalk | Senders of it, Implementors of it, Browse it, Instances of it | ⇧⌘N, ⇧⌘M, ⇧⌘B, ⇧⌘I |
| Help | Keyboard Shortcuts, Kajo on GitHub | none |

The shifted keys were chosen because ⌘B is the Browser, ⌘N is File > New
App…, ⌘M is the system's Minimize; none of ⇧⌘N, ⇧⌘M, ⇧⌘B, ⇧⌘I is taken by
the Tools menu, the Edit menu (⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A), the app menu
(⇧⌘P Pairing…, ⌘H, ⌘Q) or File (⌘N). ⌘S has no other owner in the app
(there is no Save). Senders of it, Implementors of it and Browse it act
on "it": the selection, or the word the insertion point is in (letters,
digits, colons, underscores); a keyword message's keywords are joined
(`at: 1 put: 2` is `at:put:`). Browse it selects a class (`Foo`, `Foo
class`) whatever the package filter, goes to `Foo>>bar`, and otherwise
lists implementors. Instances of it evaluates `(it) instanceCount` and
`(it) allInstances: 1000` where the pane evaluates (a workspace, an
inspector's `self`, a debugger frame) and opens an inspector whose title
ends with "(1000 of 69795 instances)" when the limit cut the list, "(n
instances)" otherwise (`InspectorModel>>note:`). The browser's messages
list and its toolbar's Senders and Implementors now go through
`BrowserModel>>sendersOf:` and `implementorsOf:`; Senders, Implementors
and Browse use an open browser on the pane's target, or open one.

**How an item reaches the focused pane.** Each tool window declares its
text panes with `ToolWindow>>pane:keys:action:`, which binds the keys of
the Smalltalk items that apply to the pane (`DevTools paneKeys`: the
Workspace and the inspector's and debugger's evaluation panes take all but
Accept; the browser's and the debugger's source panes take Accept,
Senders, Implementors and Browse), sets the pane's key action, gives it
a context menu of the same items, and records it (`textPanes`). A
Smalltalk menu item, chosen with the mouse or by a key no focused pane
binds, runs `DevTools smalltalkItem:`: it finds the pane among the open
tool windows' panes that answers `isFocused` (a new `get` of the text
view, `focused`: on AppKit, the view is the first responder of the key
window, or of the main or frontmost one while the app is not active; on
UIKit, `isFirstResponder`; headless, whether `focus` was sent) and calls
`TextView>>pressKey:`, which runs the pane's own key action with the key,
exactly as the key event does, and only for a key the pane binds. An item
that does not apply to the focused pane does nothing; context menus leave
such items out. `TextView` keeps its bound keys (`boundKeys`, a new
instance variable `keys`) so the kernel knows which apply without a host
read.

**One key, one action.** `KajoTextView` claims a bound key in
`performKeyEquivalent:` (first responder only) and answers true, so a key
the focused pane binds runs the pane's action and never reaches the menu
bar; a key it does not bind falls through to the menu. The test is
`ViewWrapperTest>>testOneKeyOneActionBetweenAViewAndTheMenuBar` (kernel,
so it runs headless, in the Mac shell's tests mode and on the iPhone): a
window with a text view binding ⌘D, a menu installed in the menu bar
with Do it ⌘D and Other ⌘E; ⌘D gives the view's action once and the menu
nothing, ⌘E gives the menu's action once and the view nothing. The key is
delivered by a new host call, `pressKey`, which builds the key-down
`NSEvent` and sends it through `NSApp.sendEvent` when the view's window is
the key window (answer `app`). It measured, and that is a deviation: a
process launched from a script is never made active on this Mac (macOS's
cooperative activation refused `NSApp.activate()` and `activate(ignoringOtherApps:)`
for the binary run directly and for `open -a`, 219 tries over 5 s), so
the window is never key and `NSApp.sendEvent` drops the key. The call then
offers the same event to the window's views (`NSWindow.performKeyEquivalent`,
which reaches `KajoTextView`) and, when none claims it, to the menu bar
(`NSMenu.performKeyEquivalent`), the order AppKit documents for a key
window (answer `emulated`, printed on the Transcript by the test). So the
run measured the real text view's claim and the real menu's match, in the
documented order, not the window server's path; an interactive run (the
owner's Mac with the shell in front) takes the `app` path. The Mac
shell's tests mode printed `cmd-d delivered 'emulated'` and `cmd-e
delivered 'emulated'` and passed. Menus installed by the test leave the
menu bar again (`Menu>>uninstallFromMenuBar`, host call `uninstall`).

**Context menus.** The Workspace's pane and the inspector's and debugger's
evaluation panes list Do it, Print it, Inspect it, Senders of it,
Implementors of it, Browse it, Instances of it; the browser's and the
debugger's source panes Accept, Senders of it, Implementors of it, Browse
it (`DiscoverabilityTest>>testEachPanesContextMenuListsTheItemsThatApply`).
On UIKit, which has no menus, `DevTools contextMenuFor:action:` answers
nil and the pane has none.

**Hints.** A new Workspace's status line is `⌘D do it · ⌘P print it · ⌘I
inspect it` (made from the Smalltalk items, `DevTools workspaceHint`)
until its first evaluation replaces it. The browser's source pane says `⌘S
accept` on the first hand edit of a shown method or new-method template
when no compile error is named (once per method shown;
`BrowserWindow>>edited`).

**Help.** Help > Keyboard Shortcuts opens a read-only window
(`ShortcutsWindow`) with `DevTools shortcutsText`: the Tools, Smalltalk and
Help menus' items with their keys, which Smalltalk items each kind of pane
takes, the browser's and debugger's toolbar commands (buttons, no keys),
and the system Edit menu's keys, all generated from the item lists and
the toolbars' `toolbarItems`. `DiscoverabilityTest>>testEveryBoundKeyIsAMenuItemsAndInTheShortcuts`
opens a workspace, a browser, an inspector and a debugger and asserts
that every key any of their five panes binds is a Smalltalk item's key and
appears (as glyphs) in the text, and that every menu item's key and title
and every toolbar command is in it. Help > Kajo on GitHub opens
https://github.com/katis/kajo through a new host op, `openURL` (handle
nil, http and https only; `NSWorkspace.open` on AppKit,
`UIApplication.open` on UIKit; `View class>>openURL:`): New App…'s open
was Swift-side only, so the smallest addition was the op, no primitive
(primitive 150 passes any op name to the host).

**Release notes.** `scripts/release.sh`'s notes gain "First steps": open a
Workspace (⌘K), type `3 + 4`, press ⌘P; the Smalltalk menu, the context
menu and Help > Keyboard Shortcuts; `"…"` is a comment and `'…'` a String.

### Finding instances: primitives 167 and 168

`Smalltalk primAllInstancesOf: classes limit: n` (167) and `Smalltalk
primInstanceCountOf: classes` (168), `Sources/KajoVM/ObjectModel/InstancePrimitives.swift`
with the walk in `Sources/KajoVM/ObjectMemory/Instances.swift`; `classes`
is a Behavior or an Array of Behaviors (each checked against the class
table), `n` a SmallInteger from 0 to 16 777 215; anything else fails and
the kernel names the reason. Against the constraints:

- **The stop.** Both run in one stop of the world of a new kind,
  `StopKind.instances`, so they appear on the run line's `stopsByKind` and
  as `"collection":"instances"` gc events. In the stop, module 1's
  promote-all hook (`prepareOldSpaceOperation` with the stop's roots) runs
  first, as for collect, compact, become, reshape and the save: a marking
  cycle is abandoned, a lazy sweep finished and applied, deferred entry
  frees released, every young object promoted. If it leaves anything
  young (old space had no block for it) the primitive fails ("the heap is
  full", as a reshape refuses). A cost to know: an `allInstances` while a
  cycle marks abandons that cycle, as every module 1 operation does.
- **Which entries count.** After the hook, sweep-stop.md's one-owner table
  leaves exactly one state that holds an object: used and old, which is
  exactly the old map's bit. A swept-but-pending entry is free with its
  old-map bit cleared (owner: the pending list) and the hook applied every
  pending run anyway; a deferred free is a young entry, owned by its
  nursery, and the hook released every one; a stash's or pool's entry is
  free and never in the old map. So the walk reads the old map's words
  below the high-water mark (64 entries per word, a zero word skipped) and
  the header of each set entry (class index from the header), with a
  belt-and-braces `isFree` check. A large object is one entry, its
  continuation blocks are not entries, so it counts once. Garbage counts
  until a collection frees it (Pharo's rule; `Smalltalk garbageCollect`
  first for the live ones).
- **Where the Array is allocated and rooted.** 167 walks twice in the one
  stop: it counts up to the limit, allocates the Array, and fills it. The
  Array is allocated in the stop directly in old space through the object
  memory (`ObjectMemory.allocate` with the stop's roots, as a class
  definition's objects and a reshape's bodies already are), never through
  the mutator's path. The rule: no worker, the main one included, may
  allocate through the mutator's path inside a stop, because that path may
  itself need a stop (a scavenge, a full collection) or wait for the
  marker or the sweep, and the stopper can do neither; the object memory's
  old allocation in a stop is allowed because nothing is young and no
  cycle runs after the hook, so the Array needs no barrier, remembered
  word or snapshot bit and its stores need none. An Array past 4095 slots
  is a large object, old at birth (a run). It is rooted by the primitive's
  answer: the worker passes no poll and no allocation between the stop's
  release and the interpreter's push of the answer, so it is never "held
  only by the stop that allocated it" when its worker parks (module 10's
  lesson); no pending root is needed. If that allocation had to collect
  (old space full), garbage the count included may have been freed: the
  fill then finds fewer and the answer is a second, exact Array (the
  first one an extra root). The answer is never one of its own elements
  (`Array allInstances` skips it).
- **Chunking.** Not built: every measured stop was under 5 ms on the Mac
  (below), so the walk does not poll and nothing is filled across stops.
- **Immediates.** SmallInteger, SmallFloat and Character have no heap
  instances and answer `#()`; nil, true and false are their classes' one
  instance (`Behavior>>allInstances` says so; `ReflectionTest>>testTheImmediatesAndTheSingletons`).
- **Release images.** Both work in a release image: they read, as
  `slotAt:` does, and change nothing.

The kernel (`Behavior`, category `instances`): `allInstances` (limit
100 000, open question 3), `allInstances:`, `allSubInstances` and
`allSubInstances:` (one walk with every behavior that `includesBehavior:`
the receiver; deviation: the classes come from `Smalltalk allBehaviors`,
not `withAllSubclasses`, so metaclasses are included and `Class
allSubInstances` answers every class, as in Pharo; `withAllSubclasses`
lists no metaclass), `instanceCount`; `instancesOf:limit:` checks the
limit before the primitive. Tests: `ReflectionTest` gains six (a fresh
instance appears and a dropped one disappears after `Smalltalk
garbageCollect`, the limit, a class with none answers `#()`, the
immediates and singletons, `allSubInstances` includes a subclass's
instance and `allInstances` does not, the count equals the size under the
limit) over two probe classes in Kernel-Tests (`ReflectionTestProbe`,
`ReflectionTestSubProbe`); `Tests/KajoVMTests/ObjectModel/InstancePrimitivesTests.swift`
(five: young instances found in a stop of kind `instances`, the limit and
a large answer, garbage until a collection, a marking cycle abandoned and
a pending sweep applied with no verifier failure, an Array of classes
walked once and the answer not its own element); `ExtremeIntegerTests`
calls 167 with minVal, maxVal, -1, 0 and 1 as the limit (and as the
classes) and 168 with each as its argument. The Smalltalk menu's
"Instances of it" is the tools' side (open question in the brief:
the menu item, as recommended).

### Measurements

**The stop** (`stops/`: `kajo test` on the development image, kernel,
tools, the shell's Smalltalk and the devsession, plus a measuring test
class, and on the same with the 1806 generated classes, 4 workers,
release build, the per-stop gc events; ten stops per row, ms):

| Walk | dev p50 | dev max | 2000 p50 | 2000 max |
|---|---|---|---|---|
| `Object allInstances: 1` | 0.049 | 0.071 | 0.296 | 0.365 |
| `ReflectionTestSubProbe allInstances` (whole walk, nothing found) | 0.048 | 0.051 | 0.308 | 0.315 |
| `String allInstances: 100000` | 0.161 | 0.180 | 0.716 | 0.751 |
| after 1.2 million garbage Objects: `Object instanceCount` | 1.480 | 3.341 | 1.785 | 3.796 |
| the same: `String allInstances: 100000` | 1.695 | 1.708 | 3.156 | 3.223 |
| after `Smalltalk garbageCollect` (high-water mark stays): the empty walk | 0.057 | 0.063 | 0.309 | 0.334 |
| the same: `String allInstances: 100000` | 0.164 | 0.179 | 0.702 | 0.741 |

Strings found: 8104 and 53 254. `Object allInstances: 1` finds nothing on
these images (no direct Object instance), so it is the whole walk without
the fill. The maxima of 3.3 and 3.8 ms are the first stop after the churn,
whose promote-all moved 1.2 million young objects; with that garbage in
old space every later walk reads 1.2 million headers (1.5 to 3.2 ms); after
a collection the walk is back at its size with the high-water mark still
at 1.25 million, because zero old-map words are skipped 64 entries at a
time. The slowest stop measured is 3.8 ms, under the 5 ms bound: no
chunking.

**Frames** (`frames/`): the Mac shell's `mode=devsession session=instances`
(the scripted session's frame account, new: `DevSessionBench
startInstances:`), on the Mac mini's 120 Hz display, two launches each on
the development image and the 2000-class image. The tools open on the
image's own socket; one step checks the bar's instance answers through the
tools' client; then a Workspace window holds `(String allInstances:
100000) size` and its Do it runs ten times by its own key action, each
evaluation a step timed until its answer, each step's frames counted by
the shell (`steps_ms_missed`). 0 frames missed in all 40 evaluation steps
(5.3 to 20.0 ms each, the first of each launch the longest); the launches'
whole windows missed 18, 13, 21 and 18 frames, all outside the evaluation
steps (the windows opening; 9c's known AppKit cost). The Workspace
evaluates the Array's size, not the Array: an Array's printString is
printed whole before the protocol cuts it at 4000 bytes, and each
element's printString is a new String the next walk finds, so a first run
printing the Array doubled the count and the time at every evaluation
(179 ms to 15.6 s by the seventh, which timed out the session), a cost of
`DevSession>>describe:`, not of the walk, recorded under not done.

**The bar's checks** on the shell's images (the `instances.check` step,
after `Smalltalk garbageCollect`): `ToolWindow allSubInstances size` 3 =
`DevTools windows size` 3; `Class allSubInstances size` 210 = `Smalltalk
allClasses size` 210 (2016 = 2016 on the 2000-class image); `(String
allInstances: 1000) size` 1000 (of 10 196 and 69 795); `SmallInteger
allInstances` `#()`.

**Tests.** The kernel tests 218 of 218 headless (`just kernel-test`), 218
of 218 in the Mac shell's tests mode and 218 of 218 on the iPhone 13 Pro
(`iphone/`, thermal nominal, 5.2 s); the development image's tests (kernel
and tools) 255 of 255, `DiscoverabilityTest` 7 of 7.

**`interpret` and the A/B.** `just arc-check` passes (no retain or
release on the checked paths, the dispatch loop one jump table). The new
primitives are one more case in `primitive(_:_:_:)`, which `interpret`
calls out of line; `interpret` in `Dispatch.o` of the aligned
`-enable-testing` builds of 194d8ed and 32c0a44 is identical, 1817 lines
each with an empty diff, addresses included. `scripts/ab.sh 194d8ed` (5
interleaved runs, aligned builds, checksums equal everywhere): 0.997 to
1.010 at 1 worker with instruction ratios 1.000 (st-closures 1.010 with
its cycles 1.009: a Smalltalk kernel built from the changed kernel
classes), 0.964 to 1.022 at 8 workers with overlapping ranges and
instruction ratios 0.997 to 1.000, as earlier modules' 8-worker spread.

**The round trip.** `scripts/canonical-tonel.sh --check` lists no file on
every kernel and tools commit and on 32c0a44 (the Tonel files are in the
image's form; `canonical-tonel.sh` was run after each hand edit).

### `just check`

`just check 194d8ed` on 32c0a44 picked the core tier (chosen by
`Interpreter/Primitives.swift`, `ObjectMemory/Instances.swift`,
`ObjectModel/InstancePrimitives.swift` and `Workers/VMState.swift`; 33
files in the diff), toolchain swift.org 6.4.2 first on PATH, and every
gate passed in 12 480 s. Its `gates.log`:

```
2026-11-09 10:17:05 32c0a44 end clean-build rc=0 22s
2026-11-09 10:23:57 32c0a44 end swift-test rc=0 412s
2026-11-09 10:32:45 32c0a44 end swift-test-load rc=0 528s
2026-11-09 11:20:53 32c0a44 end tsan rc=0 2888s
2026-11-09 12:19:26 32c0a44 end tsan-load rc=0 3513s
2026-11-09 12:19:41 32c0a44 end ios-check rc=0 15s
2026-11-09 12:19:47 32c0a44 end arc-check rc=0 6s
2026-11-09 12:20:56 32c0a44 end golden rc=0 69s
2026-11-09 12:22:31 32c0a44 end test-release rc=0 95s
2026-11-09 12:22:52 32c0a44 end model-check rc=0 21s
2026-11-09 12:24:02 32c0a44 end soak rc=0 70s
2026-11-09 12:34:42 32c0a44 end fuzz-kasm rc=0 640s
2026-11-09 12:44:46 32c0a44 end fuzz-snapshot rc=0 604s
2026-11-09 12:54:56 32c0a44 end fuzz-syntax rc=0 610s
2026-11-09 13:05:04 32c0a44 end fuzz-protocol rc=0 608s
2026-11-09 13:07:01 32c0a44 end apps rc=0 117s
2026-11-09 13:08:14 32c0a44 end kernel-test rc=0 73s
2026-11-09 13:12:16 32c0a44 end new-check rc=0 242s
2026-11-09 13:17:37 32c0a44 end ab rc=0 321s
2026-11-09 13:30:40 32c0a44 end matrix-mac rc=0 783s
2026-11-09 13:44:43 32c0a44 end matrix-iphone rc=0 843s
```

399 + 121 Swift tests in every test gate, ThreadSanitizer 0 reports alone
and under load, 218 kernel tests, the four fuzzers with "libFuzzer build:
ok" at 2.22 (kasm), 3.35 (snapshot), 0.85 (syntax) and 1.78 (protocol)
million runs in 601 s, the gate's own A/B 0.990 to 1.011 at 1 worker and
0.982 to 1.019 at 8 with instruction ratios 0.999 to 1.003. The Mac
matrix (warm-up 0 of 1200): every row but two at 0 frames missed and 0
fallbacks; the ring under `young=stw` at 7 workers 167, 180 and 191 frames
behind 8, 9 and 8 counted soft-limit fallbacks (compacting full
collections of 198 to 212 ms, the oracle row's known cost) and the hog
with the budget off 1193 by design. The iPhone matrix at 5 workers
(warm-up 0 of 1200, built and signed in 11 s with no prompt): 0 fallbacks,
the ring under `young=stw` 3, 7 and 4 frames behind 14.1 to 16.9 ms
scavenges as before, the hog 1192 by design. The core tier does not list
the tools' tests or the Mac shell's tests mode; both ran before it (255
of 255 and 218 of 218).

### Deviations

- One key, one action was measured on the real `KajoTextView` and the
  real menu bar in AppKit's documented order for a key window, not
  through the window server: macOS did not let a scripted launch become
  active, so its window was never key (above). The test takes the
  window-server path by itself whenever the window is key.
- `allSubInstances` takes its classes from `Smalltalk allBehaviors`
  (every behavior that `includesBehavior:` the receiver), not
  `withAllSubclasses`, so metaclasses count and `Class allSubInstances` is
  every class; `withAllSubclasses` has no metaclasses.
- The frame measurement's Workspace evaluates `(String allInstances:
  100000) size`: printing the Array itself made every evaluation find
  the previous one's printStrings (above).
- `instanceCount` and the shell's `session=instances` are additions the
  brief did not list (the count is what Instances of it puts in the
  inspector's title; the session is how the frames were counted).

### Not done

- The window server's own path for one key, one action (an interactive
  run of the tests mode with the shell in front would take it).
- `DevSession>>describe:` prints a whole collection before cutting the
  printString at 4000 bytes (an inspector or a doit on a large Array
  costs the whole print).
- Chunked walks: not needed at the measured 3.8 ms; a heap of tens of
  millions of old entries would need them.
- UIKit has no Smalltalk menu, context menus or Help menu (it has no
  menus); the panes' keys work there with a hardware keyboard.
- Instances of it is not offered on source panes (the brief's list).
- The iPad.

### Open questions for the owner (built as recommended)

1. `pointersTo:` with the same walk? Built: not now. (The PLAN commit
   62e4281 of 2026-11-09 queues it as a module of its own after this
   one.)
2. The Smalltalk items in the Edit menu too? Built: no, the Smalltalk
   menu and the panes' context menus only.
3. `allInstances` with a default limit or none? Built: a limit of
   100 000, `allInstances:` for more.
