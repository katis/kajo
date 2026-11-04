# Follow-up: the image after the VM ends, and the file primitives' last link

Status: brief, 2026-11-04, from module 8e's open question 5 and its Not
done note on links (`docs/modules/live-classes.md`). A small follow-up,
not a module of `docs/PLAN.md`; built by the same rules.

## What is wrong

**The image is not whole after a VM ran with nurseries.** Module 8e's
tests first saved an image on the host (`Image.saveImage`) after a VM
with the default nursery configuration had run on it, and module 1's
verifier trapped ("free entry ... is in no free list"). The same happens
on the commit 8e started from with any kernel method. `VM.destroy`
uninstalls the nursery and destroys the workers; whatever lives in the
nurseries, and whatever entries their allocation contexts hold, is not
handed back to the object memory. Nothing in the product reaches this
today: the image build and every test save through the VM's own save, or
run without nurseries first. 8e's tests run without nurseries for this
reason (`TonelRoundTripTests.runSmalltalk`'s comment).

The rule this follow-up sets: **after `shutdown` and `destroy`, the image
the host holds is whole.** Every object reachable from the image's roots
is in old space; every entry the VM took and did not use is back in a
free list; the verifier passes; `Image.saveImage` yields an image that
loads, verifies and runs. The owner's workflow needs this: a developer
ends a VM and saves what it made.

**The read primitive follows a symbolic link in the last path
component.** `sourcesPath` (`ObjectModel/LiveClasses.swift`) resolves the
parent directory through links and requires it to stay under the sources
directory, but the last component is not resolved: a link planted in the
directory with that name is followed by `open` in the read primitive
(149), so a file outside the directory can be read through it. A write
(148) replaces the link itself with `rename`, which is safe. The rule
this follow-up sets: **no path reaches a file outside the sources
directory, through any component.**

## What to build

1. **A whole image at VM end.** Decide and document the mechanism; the
   likely one is a final stop-the-world young collection in `shutdown`
   (after the workers have joined and before the collectors stop) that
   promotes every live young object and empties every nursery, followed by
   handing every cached entry back to the object memory's free lists in
   `destroy`. Module 4 (`docs/modules/nursery.md`) and module 7
   (`docs/modules/young-collection.md`) describe the nurseries, the
   allocation contexts and the entry caches; module 1
   (`docs/modules/object-memory.md`) the free lists and the verifier. If
   the mechanism needs a cross-thread protocol the models under `models/`
   do not cover, model it first (the rules in AGENTS.md).
2. **Tests.** A VM with the default configuration runs kernel code that
   allocates young objects reachable from a global (a class variable or
   a class-side instance variable), ends, and the host saves the image:
   the verifier passes, the saved image loads and the global still holds
   the objects with their contents. The same under every young-collection
   mode (`stw`, local, offload) and with 1 and 8 workers. A broken variant
   run by hand (skip the final collection) shows the verifier's failure,
   as the brief's starting point does.
3. **Remove the nursery-free workaround** where 8e's tests used it only
   for this reason (`runSmalltalk`'s nursery.bytes = 0, and any other),
   so the tests run under the default configuration; keep any that needs
   the stop-the-world collector for another documented reason.
4. **The last link.** `sourcesPath` resolves the whole path when the file
   exists (realpath of the full path must stay under the directory) and
   the read primitive opens with `O_NOFOLLOW`; the write primitive's
   `rename` keeps its behaviour but a path whose last component is a link
   leading outside is refused like any other. Extend
   `LiveClassTests`' link test with a link as the last component, for read
   and write, inside and outside the directory. Update the 8e doc's Not
   done entry and its open question 2's "no way out through links".

## Rules

Those of AGENTS.md. The young collector's paths are hot: a final
collection at shutdown must add nothing to the hot paths (`just
arc-check`, `just bench` A/B within noise). Zero behaviour change for a
VM that saves through its own save primitive: the saved-process rules and
the save-hold model stay as they are.

## Deliverables

The code, the tests, this file replaced by the as-built description (what
the mechanism is, measurements of the final collection's cost at shutdown
for an empty nursery and a full one, deviations, unsafe surface, hot-path
check, not done, open questions, gates, commands), module 8e's doc
updated (question 5 closed, the link entry closed), `docs/modules/nursery.md`
gaining a paragraph on the VM's end, `docs/CONTEXT.md` if a term is new.
