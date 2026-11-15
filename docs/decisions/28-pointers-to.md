# The pointersTo: follow-up

The `pointersTo:` follow-up, built 2026-11-09
(`docs/modules/pointers-to.md`, the owner's second reflection tool):
primitives 169 `pointersTo:limit:` and 170 `pointerCountTo:` run in the same
`instances` stop after the promote-all hook and compare every slot of every
old pointer object raw against the argument (weak slots and a large object's
run included, byte objects skipped by format, the class not a slot, a method
listed for its literal frame and the frame itself not, the answer Array
skipped, a self-reference listed, an immediate argument allowed; Process
stacks are not in the heap and are not read, so an object held only by a
frame answers `#()`, while a saved stack in an image is found as a slot of
its chunk); the walk's premise was measured before anything was decided (the
brief's part 1a): the first build's worst stop was 12.4 ms on the
development image with 1.2 million garbage objects and 14.9 on the
2000-class image, and three changes to the still-unbounded walk, each
measured, brought it to 4.7 ms (one walk into a host buffer with the Array
filled from it and a second walk only when the allocation collected, tested
under `collectAtEveryAllocation`; eight slots per vector compare with plain
loads in the stop; the literal-frames pass only when a read-only Array holds
the argument), so chunking is not built and its design is a paragraph (the
2000-class image with the garbage still reaches 5.9 to 6.4 ms at its first
stop, promotion included); without garbage a whole walk is 0.17 to 0.27 ms
p50 on the development image (1.2 to 1.3 ns a word over 103 000 to 134 000
words) and 0.8 to 1.1 on the 2000-class image; the stop record and gc event
carry `words`; the kernel's `Object>>pointersTo`, `pointersTo:` and
`pointerCount`, ten `ReflectionTest` tests, `PointersToTests` and
`ExtremeIntegerTests`; the tools' "Objects pointing to it" (⇧⌘O) wherever
Instances of it is offered, opening an inspector titled with how many
objects point to it, and the Inspector's slots menu on the inspected object
and on the selected slot's value; `mode=devsession session=pointers` (0
frames missed in 40 `pointersTo: 100000` evaluations and 4 `nil
pointerCount` steps; a first version that ran the count in a freshly opened
window missed 1 frame to AppKit's window opening, reordered); `interpret`
identical, the aligned A/B against 54bd2a6 0.993 to 1.003 at 1 worker and
0.970 to 1.031 at 8 with instruction ratios 0.997 to 1.001; by the owner's
answer of the same day `pointersTo`, `allInstances` and `allSubInstances`
have no default limit (the largest Array the only bound, the explicit forms
for less, the stop-a-frame warning kept as a warning; the tools' lists stay
bounded at 1000); `just check 54bd2a6` on d326190, the core tier, every gate
in 12 253 s (408 + 121 tests, ThreadSanitizer 0 reports alone and under
load, 228 kernel tests headless, in the Mac shell and on the iPhone, the
four fuzzers with "libFuzzer build: ok" at 0.82 to 3.36 million runs, the
Mac matrix's ring under `young=stw` 168 to 184 frames behind 8 to 9
fallbacks and every other row 0, the iPhone 0 fallbacks and 4 to 5 frames in
the same row; a first run on e8dab54 stopped in its third gate when the
owner's answer arrived, so the gates ran on the final code); not done:
chunked walks, the session's handle table listed as a holder of what a tool
holds, weak holders not marked in the inspector, UIKit menus, the iPad; its
three questions answered by the owner as recommended (weak holders listed,
stacks not scanned, immediates allowed).
