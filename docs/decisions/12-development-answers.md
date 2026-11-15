# The development answers

The development answers built on 2026-11-07
(`docs/modules/development-answers.md`, ADR 0011's and 0012's Built
(development answers) notes): a development image stops an unhandled error's
Process wherever its host says a debugger can come: one host setting
(`Headless.Options.stopsForDebugger`, false by default, an atomic in
`ShellBridge`, read by the kernel through primitive 165 and always false in
a release image), turned on by the development app before the image resumes
and by `ShellVM.openProtocol()` so every serving host stops; batch hosts
(`kajo run`, `kajo test`, the image build, the fuzz targets) have no bridge
and report and end, each with a test that a forked Process's error ends the
host within a bound; `UnhandledError>>defaultAction` reads only `Debugger
stopsErrors`; standing stops are capped at 32 (`Debugger stopCap`; past it
the error is reported, the Process ended, `refusedStops` counted and a
Transcript line written), listed to a later client in `session.open`'s
answer from the summary the Process made when it parked (the tools open a
debugger for each on connect; an error with no client, a client connecting
later, defining the method and retrying to 42 is tested end to end), survive
a snapshot and are listed by the resumed image, and an error in the app's
start-up stops while serving still starts; the event loop hands over
whenever `Debugger canStop`; `Transcript showLine:` because concurrent
`show:` then `cr` merged lines; the author mark is the pragma `<author:
#'agent:<name>'>` on its own line after the pattern, comment and leading
pragmas (an agent's compile leaves exactly its own author pragma, a
developer's compile is the source as written; `Smalltalk
authorOfSelector:in:` reads it, the authors table is gone, `Pragma allNamed:
#author:` answers the agent's methods, the writer writes only the category
and both readers ignore unknown keys as Pharo's Tonel does, the one fixture
that carried the key rewritten in its own commit f7a760c);
`Process>>terminate` answers whether the unwinding ran to its end, a new
kernel class `Unwinding` notes each unwind block and counts cut-offs, each
cut-off writes a Transcript line naming the Process and the block,
`process.terminate` answers `{process, unwound, cutOff}`, the debugger's
terminate uses the same bound and restart and retry answer after their
unwinding and say where it stands past 1 s; measured 2026-11-07 at thermal
nominal: a standing stop holds 16 to 18 KB once warm and a full cap 528 to
576 KB, the Mac mini and the iPhone 13 Pro missed 0 of 1266 frames in the 10
s window with the event loop stopped and no client (1 stop and a full cap of
32) and 0 after a client connected and proceeded, the one frame some runs
missed falling where serving starts, `session.open` with the stops 10 to 17
ms on the Mac and 23 to 30 on the phone; the VM change is the setting alone
(5 files, 56 lines, no `unsafe`), `interpret` identical but for four page
offsets, the A/B 0.991 to 1.014 at 1 worker and 0.940 to 1.080 at 8 with
`sends` on 8 at parity when re-run 10 times; 9d's listener-pause test waits
120 s for its report everywhere (its 10 s ran out behind twelve busy loops
without the sanitizer); the gates on f6024a3 read 369 + 112 Swift tests and
205 kernel tests, the four fuzz targets run at the same time for 601 s each
with "libFuzzer build: ok" and 0.92 to 2.99 million runs; not done: the iPad
rows, UI for a standing stop with no client, aging out stopped Processes;
its five open questions answered by the owner on 2026-11-07, all as
recommended (the 2 GiB - 1 limit, the per-direction transport, the devices'
extra stops accepted).
