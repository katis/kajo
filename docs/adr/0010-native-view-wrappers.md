# ADR 0010: Native views behind Smalltalk wrappers and one hop primitive

Date: 2026-11-04
Status: accepted (owner, 2026-11-04, on module 9a's Mac mini and iPhone 13 Pro measurements, `docs/modules/shells.md`)

## Context

ADR 0004 put Smalltalk UI code on the main thread with budgeted
preemption and chose UIKit and AppKit, imperative toolkits that suit direct
wrappers, over SwiftUI. Module 9a needs the first wrappers: enough for the
measurement window of the device scenarios (a label, a slider, a text view,
a view moved every frame) and for a demo the owner opens. How a Smalltalk
object names a native view, who keeps the view alive, how a native event
finds its wrapper, and where the platform difference lives are decisions
every later wrapper inherits.

## Decision

- **A handle table in the shell.** The shell owns the native object (an
  NSView, NSWindow or UIView) in a table keyed by a positive SmallInteger
  handle it chooses; the wrapper holds only the handle. No oop is stored in
  native code and no native pointer in the heap, so the collector moves
  wrappers freely and a snapshot holds nothing native.
- **One hop primitive for every view call.** `View class >>
  primCall: op handle: h with: args` (primitive 150) carries the op, the
  handle and an Array of plain values (nil, Booleans, SmallIntegers,
  Floats, Strings, Symbols) to the shell's view host and answers its value.
  On the main worker it runs in the turn, inside a blocking region (it
  touches no heap object), so set then get answers what was set, in the
  same turn (ADR 0004). Off the main thread it hops: the Process becomes
  main-affine and the send is retried on the main worker. With no shell it
  fails before hopping, so headless code never waits for a main thread no
  one turns. The ops are few and generic: `create` (a kind: window, view,
  label, button, textView, slider), `set` and `get` (a property: text,
  title, value, minimum, maximum, hidden, color, x, y, width, height),
  `frame` (x, y, width, height), `origin` (x, y: the per-frame move),
  `add` (a subview's handle), `call` (show, close, appendLine, clear).
- **The protocol is the same on AppKit and UIKit.** The kernel classes
  (View, Window, Label, Button, TextView, Slider) say what a view does; the
  shell's view host says how (`apps/KajoShell-macOS` AppKit,
  `apps/KajoShell-iOS` UIKit). Coordinates are points with y down on both
  (the macOS host flips its containers). A Window is an NSWindow on macOS
  and a full-screen container in the iOS shell's one window.
- **Lifetime: the finalization Process releases a dead wrapper's view.**
  Every wrapper is registered by handle in a weak table (a WeakArray cell
  per handle, for events) and with an Ephemeron keyed on the wrapper whose
  finalizer holds only the handle; when the wrapper is collected the
  finalizer tells the shell (primitive 152, any worker, no hop), and the
  shell releases the native view on its main thread. A window holds its
  subviews' wrappers, so a window's views live while the window does. A
  Window closed by the user stays as a wrapper until collected.
- **Events go through the shell's event queue to one Process.** A native
  callback (a click, a slider move, a window closed) only posts an event
  (kind, handle, value, the time it happened) and runs a turn. The kernel's
  event loop, one main-affine Process at the highest priority, waits on a
  Semaphore the queue signals once per event (module 3's external-signal
  queue; no new cross-thread protocol), takes the event (primitive 154),
  finds the wrapper by handle and sends it `handleEvent:`. A handler runs
  synchronously in the run-loop turn that delivered the event; an error in
  it goes to the Transcript and the loop continues.
- **Headless, the wrappers keep their own properties.** With no shell
  (`kajo test`, `kajo run`) a wrapper gets a negative handle and stores its
  properties in a Dictionary, so the protocol and its tests run anywhere;
  the same tests run against the Swift test shell and against AppKit and
  UIKit in the apps' tests mode.
- **No layout system, no SwiftUI.** Frames are set in points. Layout,
  styling and more widgets come when an application needs them.

## Reasons

- A handle is the only thing that survives every collector the VM has
  (moving young and old objects, ADR 0007 and 0008) without a pin or a
  root in native code, and a snapshot of a heap with handles in it is
  harmless: on resume the wrappers come back detached.
- One generic primitive keeps the VM ignorant of widgets: a new property
  or widget is a shell change and a kernel method, not a VM change, and
  every call goes through the same hop, blocking region and counters.
- Finalization by Ephemeron is the kernel's existing mechanism (ADR 0009
  section 1); a weak table alone could not tell the shell that a view died.
- The event queue riding on the external-signal queue keeps the number of
  cross-thread protocols at what module 3 model-checked by argument: one
  Semaphore signal per event keeps the count equal to the queue's length.

## Costs and open problems

- **One primitive call per property.** A frame update is one call; moving
  the probe every frame is one call. A window built from scratch is tens of
  calls in one turn (about 0.02 ms each on the Mac). Batching is possible
  later without changing the kernel's protocol.
- **Strings cross by copy.** `text` and `appendLine:` copy UTF-8 both ways.
- **Handles are not reused** within a run (the shells count up); a
  long-lived app creating millions of views would want reuse with a
  generation.
- **The wrappers' class-side state** (the table, its lock) lives in View's
  class-side variables; subclasses route to View. The kernel has no class
  variables yet (kernel-image.md "Not done").
- **Native views do not survive a snapshot.** Wrappers in a resumed image
  are detached (handle nil) and must be rebuilt by the application.
- **A modal native loop** (an NSAlert's `runModal`) would re-enter the
  run loop inside a callback; the shells use none, and the re-entrancy
  guard ADR 0004 lists is still not built.

## Consequences

- `Sources/KajoVM/Shell/` holds the public host surface (ShellVM) and
  primitives 150 to 154; `kernel/` holds View, Window, Label, Button,
  TextView, Slider, UIEvent, UIEventLoop and ViewTest.
- A shell implements `ShellPlatform` (KajoShellCore): the view host, the
  display link, the release, the status line.
- docs/modules/shells.md describes the built form and its measurements.
