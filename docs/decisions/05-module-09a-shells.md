# Module 9a: the native shells

The native shells built in module 9a (`docs/modules/shells.md`: the public
host surface `Sources/KajoVM/Shell/` over which no oop crosses, the event
queue on module 3's external-signal queue, the first view wrappers behind
one hop primitive as ADR 0010 (proposed), the AppKit and UIKit shells under
`apps/` over the shared `KajoShellCore`, the scenario matrix on the Mac
mini's 120 Hz display: 0 of 1200 frames missed in every scenario but the
ring under the stop-the-world oracle, event latency p99 2 to 3 ms, a hog on
main preempted 2414 times per 10 s with 0 frames missed; the iPhone 13 Pro
ran the same matrix on 2026-11-04 once Xcode was signed in: 179 kernel tests
pass on the phone, 0 of 1200 frames missed in every scenario but the ring
under the oracle (2), young collection stops the main thread 2 to 16 times
less than stop-the-world in every scenario including share, the marker kept
up on efficiency cores, event latency p99 3 ms, the hog preempted 2411 times
with 0 frames missed, most rows at thermal serious; on that evidence the
owner accepted ADRs 0004 to 0008 and 0010).
