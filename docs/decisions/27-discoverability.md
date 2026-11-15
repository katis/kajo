# The discoverability follow-up

The discoverability follow-up, built 2026-11-09
(`docs/modules/discoverability.md`, from the owner's first use of v0.1: the
tools' keys were bound but shown nowhere, and Pharo's `allInstances` was
wanted): a Smalltalk menu (Do it ⌘D, Print it ⌘P, Inspect it ⌘I, Accept ⌘S,
Senders of it ⇧⌘N, Implementors of it ⇧⌘M, Browse it ⇧⌘B, Instances of it
⇧⌘I) whose items act on the focused pane through its own key action (each
tool registers its panes with `pane:keys:action:`, the host's `focused` get
and `pressKey` call, `KajoTextView` taking a bound key in
`performKeyEquivalent:` so it never reaches the menu bar), the same items as
each pane's context menu, the Workspace's key hint and the browser's Accept
hint in the status line until first used, Help with Keyboard Shortcuts
generated from the menus, panes and toolbars (a test asserts every bound key
is listed) and Kajo on GitHub through a host `openURL` op (http and https
only), all three menus built from item lists in `DevTools`, the release
notes' First steps; primitives 167 `allInstancesOf:limit:` and 168
`instanceCountOf:` (`Sources/KajoVM/ObjectModel/InstancePrimitives.swift`,
`ObjectMemory/Instances.swift`) run in one stop of their own kind
`instances` after the promote-all hook and walk the old map, which then
holds exactly the used entries (pending-sweep entries and deferred frees are
applied or released by the hook, a large object counts once); 167 counts and
fills in the same stop with the Array allocated in old space through the
object memory with the stop's roots, as class definitions and reshapes do,
and rooted by the answer with no poll between (if the allocation collected,
a second Array of exactly what was found); limits 0 to 16 777 215,
immediates answer `#()`; the kernel's `Behavior>>allInstances` (limit 100
000), `allInstances:`, `allSubInstances` (one walk over `Smalltalk
allBehaviors`, metaclasses included) and `instanceCount`, in
`ExtremeIntegerTests`; measured: `Object allInstances: 1` 0.049 ms p50 on
the development image and 0.30 on the 2000-class image, `String
allInstances: 100000` 0.16 and 0.72, with 1.2 million garbage objects 1.5 to
3.4 ms and the slowest stop 3.8 ms, so no chunking; a Workspace evaluating
the walk ten times by its Do it (`mode=devsession session=instances`, frames
counted per step) missed 0 frames in 40 evaluations; `interpret` identical,
the aligned A/B against 194d8ed 0.997 to 1.010 at 1 worker and 0.964 to
1.022 at 8 with instruction ratios 0.997 to 1.000; `just check 194d8ed` on
32c0a44, the core tier, every gate in 12 480 s (399 + 121 tests,
ThreadSanitizer 0 reports alone and under load, 218 kernel tests headless,
in the Mac shell and on the iPhone, the four fuzzers with "libFuzzer build:
ok" at 0.85 to 3.35 million runs, the Mac matrix's ring under `young=stw`
167 to 191 frames behind 8 to 9 fallbacks and its warm-up and first idle row
0 of 1200, the iPhone 0 fallbacks and 3 to 7 frames in the same row);
deviations: one key, one action measured in AppKit's documented order (the
window's views, then the menu bar) because macOS refused to activate the
scripted shell so its window was never key, `Class allSubInstances` answers
every class, the frame measurement evaluates the Array's `size` (printing it
re-found the previous runs' printStrings and doubled the work each time, to
15.6 s); not done: the window-server key path, UIKit has no menus, Instances
of it on source panes, `DevSession>>describe:` printing a whole collection
before cutting it, the iPad; its three questions answered by the owner on
2026-11-09 (`pointersTo:` its own module, no Smalltalk items in the Edit
menu, and no default limit for `allInstances`, Pharo's rule, against the
recommended 100 000: built in the `pointersTo:` follow-up, whose
`pointersTo` has none either).
