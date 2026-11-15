# Module 8d: live methods, class variables, the release flag

The owner answered 8b's and 8c's questions on 2026-11-04: per-iteration temp
vectors as Pharo, class variables, installing from Smalltalk behind a
release flag, the rest as built; built in module 8d,
`docs/modules/kernel-live.md`: an inlined loop body owns the temp vector of
its captured and assigned temps and makes a new one per pass, in both
compilers, 10.8 ns per such iteration; class variables as Binding objects in
a read-only pool the metaclass holds, no new bytecode; the make primitive
143 over the image build's own `MethodBuilding`, primitive 85 running a made
method once, 97 and 98 refusing sealed classes and release images, the
release flag in the image header set by `kajo build-image --release` or
`kajo seal` and never cleared, `Behavior>>compile:` keeping sources and the
pragma index, `Compiler evaluate:`; 1500 seeded mutations through the make
primitive and a make-and-run fuzz mode; two 8b bugs fixed: the sources table
could not pass one block and a build step dying in an unhandled error went
on, and a message chain of thousands overflowed the parser's stack; its four
open questions answered by the owner on 2026-11-04.
