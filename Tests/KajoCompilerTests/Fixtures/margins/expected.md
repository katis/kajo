### Margins the tests printed (run)

Gates read: swift-test, swift-test-load, tsan. A cell is value/bound (fraction) in the row's unit; xN: printed N times, the largest fraction kept. THIN: 0.8 or more in any gate; PAST: 1 or more.

| margin | kind | unit | swift-test | swift-test-load | tsan | largest | previous | mark |
|---|---|---|--:|--:|--:|--:|--:|---|
| Past.wait | deadline | s | - | 130/120 (1.08) | - | 1.08 | new | PAST |
| Thin.wait | quiet | s | - | 50.0/60.0 (0.83) | - | 0.83 | 0.50 | THIN |
| Interleaved.b | ceiling | ms | 180/30000 (0.01) | 23500/30000 (0.78) | - | 0.78 | new |  |
| Twice.wait | deadline | s | 9.0/30.0 (0.30) x2 | 12.0/30.0 (0.40) | - | 0.40 | new |  |
| Interleaved.a | quiet | s | 3.0/60.0 (0.05) | 6.0/60.0 (0.10) | - | 0.10 | new |  |
| OnlyPlain.wait | deadline | s | 0.400/10.0 (0.04) | - | - | 0.04 | new |  |
| Plain.wait | deadline | s | 1.2/120 (0.01) | 4.0/120 (0.03) | - | 0.03 | 0.01 |  |
| Body.time | time | s | 17.5 | 80.0 | - | - | new |  |

### The gates' own times against their bounds (gates.log)

| gate | rc | seconds | bound | fraction | mark |
|---|---|--:|--:|--:|---|
| clean-build | 0 | 19 | 3600 | 0.01 |  |
| swift-test | 0 | 720 | 3600 | 0.20 |  |
| tsan | 1 | 9581 | 10800 | 0.89 | THIN |
| kernel-test | 0 | 126 | - (not logged) | - |  |
| fuzz | 0 | 601 | 720 | 0.83 | THIN |
| ab | skip | 0 | - (not logged) | - |  |

- UNKNOWN: 2 line(s) with `kajo-margin` that do not parse (not rows, not passes):
  - swift-test-load.txt:4: `kajo-margin name=Broken.wait kind=deadline value=3.000 unit=s`
  - swift-test-load.txt:5: `✘ Expectation failed: (x → kajo-margin name=Quoted.wait kind=deadline value=1.000 bound=2.000 unit=s)`
- Printed more than once in a gate (the largest fraction kept): Twice.wait in swift-test x2
- Absent from a whole-suite gate that has output: Body.time (not in tsan); Interleaved.a (not in tsan); Interleaved.b (not in tsan); OnlyPlain.wait (not in swift-test-load, tsan); Past.wait (not in swift-test, tsan); Plain.wait (not in tsan); Thin.wait (not in swift-test, tsan); Twice.wait (not in tsan)
- Gone since the previous run: Gone.wait
- No output here for: tsan-load, test-release, soak, compiler-tests
