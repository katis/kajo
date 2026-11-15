# The runtime comparison and the performance report

The runtime comparison and the performance report (2026-11-07,
`experiments/runtime-comparison/`, `docs/performance/README.md`, `just perf`
and `just perf-report`, `scripts/perf-report.py` with a fixture test): the
same five programs (fib, dispatch, binarytrees, collections, arith) with one
checksum each in Kajo (kasm and Smalltalk, 1 and 8 workers), Pharo 12's Cog,
C, LuaJIT with and without its JIT, Lua 5.4, Node with and without, Java G1,
`-Xint` and ZGC, Ruby with and without YJIT and CPython, five interleaved
rounds on the mini, 341 runs none refused at thermal nominal; on one thread
Kajo is level with Java `-Xint` on fib (47 M calls/s), ahead of Node
`--jitless`, Ruby, Lua and CPython on binarytrees (14 M objects/s), behind
every interpreter but CPython on dispatch (15 M sends/s) and arith (675 M
bytecodes/s), and LuaJIT's interpreter is 2.3 to 2.6 times faster on all but
binarytrees; 8 workers scale 6.1 to 7.4 times; the kernel's collections take
4.3 times Pharo's; the report's part 0 says what kind of VM and collector
this is and what each choice costs; found on the way: the 8-worker rows' 19
to 30 ms stops are the finished sweeps for an empty entry table
(`sweepsForEntries`), a collector follow-up in `docs/PLAN.md`.
