# Module 9c: the developer UI

The developer UI built in module 9c, `docs/modules/developer-ui.md`, as a
Smalltalk package `tools/` (27 classes: `DevClient`, a model and a window
each for the browser, workspace, inspector, debugger, test runner,
transcript and target picker, tested against a fake client) compiled into a
development image by `kajo build-image --with tools` (`just dev-image`,
`just tools`; ADR 0013, proposed), speaking the protocol even to its own
image through primitive 164 and `KajoDev.ClientHost` (the host owns the
sockets and the token, replies and the connection's end arrive as events on
9a's queue, timeouts as timer events); while the protocol serves, an error
in a tool hands the event loop to a new Process and the stopped one opens a
debugger (define-and-proceed tested end to end); the second round of
wrappers (text view with selection, styles, bound keys and change events;
outline, table, split, scroll, toolbar, menus, window frame) on AppKit, the
text view's new features only on iOS; the tools push items to the views, the
on-demand form is built and measured (ADR 0010's Built (9c) note); a view
call past the turn's deadline makes the next poll check the budget (longest
turn 40 to 13 ms); no object passed one heap block then, so `LargeArray`, a
merge sort and pieced JSON lines went into the kernel and an oversize
request was refused with a reply (module 10 removed `LargeArray` and lifted
the request limit to 16 MiB; the merge sort and the pieces stay); on the Mac
mini's display at 120 Hz a scripted session over 2009 classes and 22 284
methods ran in 3.7 to 3.9 s missing 26 to 32 frames of about 450, mostly
AppKit opening the first windows, typing under load p50 2.3 ms and p99 2.9
ms, idle p50 5.5 ms with unexplained frame misses, `class.hierarchy` 0.33 s
and `package.selectors` 0.7 s round trips, bench A/B within noise and
`interpret` unchanged; the kernel has 200 SUnit tests and `tools/` 25; its
five open questions answered by the owner on 2026-11-05 (a large-object
space in the VM as a module of its own, push by default and on demand for
long lists, a tool's error stops for the debugger, apps against a second
target image, no token in the image).
