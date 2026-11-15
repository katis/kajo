# Module 8e: live classes

Live classes built in module 8e, `docs/modules/live-classes.md`: primitives
145 to 147 define, redefine and remove a class in the install stop,
re-checking the build's rules through the shared `ClassRules`, a
redefinition making every method again against the new shape and reshaping
every instance of the class and its subclasses by name before anything
changes (10 000 instances and 50 methods in 10.8 ms, the longest install
stop 1.04 ms), old methods forwarded to the recompiled ones or to an error
stub, a removed class kept as `AnObsoleteFoo`, the running-frame rule
refusing a change while any Process runs a method of the class, removed
class variables left as undeclared Bindings; categories, comments and class
definitions kept in the image; the Tonel writer and reader in Smalltalk over
file primitives 148 and 149 bounded to the directory `--sources` opens,
`kernel/` rewritten in the canonical form the image writes and a
byte-identical round-trip test; 1500 class-spec and 500 reshape-spec
mutations; its five open questions answered by the owner on 2026-11-04 or
closed by later modules.
