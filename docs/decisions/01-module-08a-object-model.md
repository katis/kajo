# Module 8a: object model and bytecode set (ADR 0009)

0009 object model and bytecode set (proposed, accepted in principle: weak
slots and ephemerons, immediate SmallFloat and Character, native frames
materialized into Contexts on demand, compiled closures with temp vectors,
frame-walk unwinding, classic metaclasses, UTF-8 strings, read-only bit,
bytecode set v1, unsynchronized kernel collections; its first three sections
precede module 5 and module 3 reserves the frame's Context slot; sections 2
to 11 built in module 8a: SmallFloat round-trips bit for bit against
`Double`, the dispatch loop keeps module 7's register budget with the v1
fast paths out of line, the hot kernels are within noise of module 7 and
`storeheavy` is 1.07 to 1.10 from the read-only check; the owner's answers
to 8a's questions are in the Built note: inline `class`/`isNil`/`notNil`
stay, the read-only failure is `modificationForbiddenAt:value:`, the symbol
table is weak (8b), and images hold Processes (module 8c)).
