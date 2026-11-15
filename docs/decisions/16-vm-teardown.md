# The vm-teardown follow-up

The vm-teardown follow-up, `docs/modules/vm-teardown.md`: `VM.destroy` runs
one final promote-all stop and hands every stash's entries back, so the
image the host holds afterwards is whole, `Image.saveImage` works and
another VM can run over the same image (5 to 15 µs for an empty nursery, 1.0
to 1.2 ms for a full one, in release); the file primitives resolve the last
path component too, read with `O_NOFOLLOW` and create the write's temporary
file exclusively; its two open questions answered by the owner on 2026-11-04
and built in module 10.
