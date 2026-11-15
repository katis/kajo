# Module 9b: the development protocol and the debugger

The development protocol, the debugger and the agent interface built in
module 9b, `docs/modules/development-protocol.md`, from the owner's answers
of 2026-11-04 (Swift for the compiler and the bindings, every developer tool
in Smalltalk; stepping and define-and-proceed in the first version):
JSON-lines requests as `<devProtocol>` methods of `DevSession`, 28 of them,
listed by `protocol.describe`, served by one protocol Process that runs each
request in a Process of its own, over a Unix socket with a pairing token
(`kajo run --protocol`, the Mac shell's `protocol=`), never in a release
image (ADR 0011, proposed); an unhandled error stops its Process while the
protocol serves, with no timeout, and the stopped Process runs the
debugger's commands itself: frames with named variables and source ranges
from a pc-to-source map both compilers record as the last literal (image
+1.8%), evaluate in a frame, proceed, restart, retry a send, terminate,
suspend, and stepping into, over and out decided in `pollSlow` for the
stepped Process only, so `interpret` is unchanged instruction for
instruction (ADR 0012, proposed; a step to its stop 1.6 ms, compile 0.85 ms,
evaluate 0.21 ms at p50); methods carry a package, extension files are
`<Class>.extension.st`, the author is Tonel metadata, the client writes
accepted changes to `--project` and the files rebuild the edited image;
`kajo mcp` builds its tools from `protocol.describe`, the CLI gains `eval`,
`compile`, `browse`, `debug`, `test --target` and `request`; `terminate`
runs ensure blocks within about 1 s; removed classes are freed into
class-table holes by `Smalltalk garbageCollect` (image version 4); the Mac
shell kept 1200 of 1200 frames while its event loop's Process sat stopped
for 10 s; a libFuzzer target for requests; its five open questions answered
by the owner on 2026-11-06 (a development image stops an unhandled error's
Process with or without a client, the author mark becomes a pragma, both to
be built in a follow-up; sealed extensions that only send stay; terminate's
bound stays with a cut-off never silent; an agent has the developer's rights
for now).
