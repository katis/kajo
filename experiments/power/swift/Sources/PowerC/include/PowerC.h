// arm64 wait and hint instructions for the companion thread (SPEC.md
// "Part 1"): `wfe` waits for an event or the event stream; `yield` is a
// spin-loop hint. On other architectures both are no-ops.
#ifndef POWERC_H
#define POWERC_H
void kajo_wfe(void);
void kajo_yield(void);
#endif
