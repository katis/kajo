# The large-bytes follow-up

The large-bytes follow-up built the three on 2026-11-06
(`docs/modules/large-bytes.md`, ADR 0003's and 0006's Built (large bytes)
notes, `experiments/large-bytes/`): a byte object may be 2 GiB - 1 bytes
long (`Header.maxByteLength`); from 2^24 - 8 bytes the header's count field
is a sentinel holding the length's low three bits and the length is the back
reference's words, so the bounds check `i < count` stays the fast path and
only its failure and `size` read the true length, no header bit spent,
pointer objects keep 16 777 215 slots (the experiment: a count in words
would have added three instructions to every byte bounds check), every
reader of a byte count in one table, every byte primitive over a long object
polling between 256 KiB chunks (a 1 GiB copy in 58 ms kept stops waiting at
most 0.093 ms; without polls a 256 MiB copy kept one waiting 10.1 ms),
primitive 38 copying bytes, image version 6 (snapshot 5) with the loader
refusing a length that does not fit its run and a sentinel on a short body,
the fuzz seeds upgraded plus `long-bytes.img`, broken variants as test
switches (`trustCountField`, `trustLongLength`, `noBytePolls`),
`scenario=photo`; the devices' fallbacks traced with a fallback record
(cause, phase, sweep progress, entries and blocks used, the marker's QoS)
and removed at their causes: the storm ran out of entries, not old space,
while the utility-QoS marker on efficiency cores still held the swept
entries pending their apply, so the QoS policy now watches the entry table
and is re-decided at every young collection while a cycle runs, an empty
table or an old allocation without room finishes a pending sweep in its own
stop instead of a full collection (`sweepsForEntries`, `sweepsForOld`), and
an allocation that finds a cycle still marking raises the marker and waits
for the final mark up to 100 ms, background workers only (`allocWaits`); a
first version deciding the policy at every large allocation raised the
marker for every cycle on the iPad and stopped the main thread 60 percent
longer, replaced; before: 8 to 10 of 10 storm launches at 7 workers and 8 to
9 of 10 large-churn launches fell back per device; after (c196de8, 10
launches per row per device, `dev/final2`): 0 fallbacks in 80 launches, the
iPad missing no frame, the iPhone missing 1 and 2 frames in two storm
launches at thermal serious behind final marks of 8 and 20 ms (not
fallbacks; 9a's unexamined final-mark maxima), the iPhone's large churn
stopped 71 ms per 10 s against 117, the iPad's 166 against 160 (the finished
sweeps' stops), the Mac's rows unchanged, the iPhone's CPU energy 4 to 14
percent lower with the marker's own 7 percent to 3.5 times higher; the
transport's long lines decided per direction by measurement: a reply the
image writes stays in pieces (100 `package.selectors` replies 1.19 s against
1.59 as one String, half the old-space bytes) and a line the image's client
receives is one String up to 16 MiB - 1 (`class.hierarchy` 253 to 267 ms
against 308 to 336 in the 2000-class session), the switch deleted; the
`relocateEveryLiveBlock` random programs let every started cycle finish
before the runtime stops (060116e, the investigation's one sanitizer
failure; 20 of 20 alone under the sanitizer with 12 busy loops); bench 0.966
to 1.056 with overlapping ranges and `interpret` identical but for four page
offsets, 120 new `unsafe` lines; not done: pointer objects past the field,
`ByteArray>>=` and `hash` as Smalltalk loops, host conversions refusing a
long String, the allocation measurements and part 3 on the devices, the
snapshot fuzzer running the 16.8 MB seed truncated to its 1 MiB `max_len`,
one iPad large-churn launch of an earlier block missing 2 frames behind a
19.5 ms main turn; its five open questions await the owner.
