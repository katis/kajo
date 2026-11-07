# Kajo's performance

How fast Kajo's interpreter and collector are against runtimes a reader
knows, measured on one machine on one day. The prose is written by hand; every
number, table and graph between `generated` markers is written by
`scripts/perf-report.py` from the raw files and is never edited by hand.

<!-- generated: meta -->
<!-- /generated -->

## 0. What kind of VM this is

_Written by hand; see the module docs meanwhile._

## 1. How to read these numbers

Every runtime ran on the same machine on the same day, one program at a
time with nothing else of ours running. Each number is the median of five
rounds, and the rounds are interleaved: within a round every runtime runs the
kernel once before any runs it again, so a machine that warms up or slows
down over the session slows everyone alike; the first kernel is run once
more at the end to show how much it drifted. The time is the whole process's
wall time, start-up included for everyone, so the shortest runs are partly
start-up. Each program prints one checksum, and a run whose checksum differs
from the kernel's is refused and counts for nothing: every runtime in a table
did the same work, not merely a similar loop. Kajo is an interpreter with no
JIT, and it has to stay one, because iOS does not allow one; the runtimes
with a JIT are therefore also shown with it off (`luajit -joff`,
`node --jitless`, `java -Xint`, Ruby without `--yjit`), which is the
comparison with the most to say about Kajo's own design. C at `clang -O2` is
the floor. The parameters of every program and what each gap is made of are
in `experiments/runtime-comparison/RESULTS.md`.

## 2. Sends

<!-- generated: sends -->
<!-- /generated -->

## 3. Allocation and collection

<!-- generated: allocation -->
<!-- /generated -->

## 4. Bytecodes

<!-- generated: bytecodes -->
<!-- /generated -->

## 5. The Smalltalk library against Pharo

<!-- generated: library -->
<!-- /generated -->

## 6. Scaling across workers

<!-- generated: scaling -->
<!-- /generated -->

The language experiment's Rust and Swift slices (`just bench`,
`experiments/vm-language-bench`), the evidence ADR 0001 rests on: the same
kasm kernels at their original sizes on a minimal VM, not Kajo's core.

<!-- generated: slices -->
<!-- /generated -->

## 7. On the devices

<!-- generated: devices -->
<!-- /generated -->

## 8. Caveats

<!-- generated: caveats -->
<!-- /generated -->

## 9. Reproducing

`just perf` runs the comparison (`experiments/runtime-comparison/bench.sh`,
about an hour), then `just bench`, then regenerates this file and its graphs;
`just perf-report` regenerates them from the raw files alone. The runtimes are
Homebrew's (`brew install lua luajit openjdk ruby`, Node from the machine's
own install) and Pharo 12 from its zeroconf download into
`experiments/runtime-comparison/pharo/`. Versions of this run:

<!-- generated: versions -->
<!-- /generated -->
