# Decision records

One file per module or follow-up, in the order the work was recorded: what
was measured and decided, the numbers, the gates, deviations, what was not
done, and the owner's answers to its open questions. `AGENTS.md` lists
them; `docs/adr/` holds the architecture decisions themselves and
`docs/modules/` each module's brief and description.

Files 00 to 37 were one paragraph of `AGENTS.md` until 2026-11-15 and were
moved here word for word (only the first letter's case and the punctuation
at each cut changed), so each is one long sentence chain. A record written
after that date is ordinary prose with the same contents.

Rules (`docs/PROCESS.md` "Recording"):

- A new record is a new file, numbered next, and a line in `AGENTS.md`'s
  list in the same commit.
- A record is not rewritten. A later answer of the owner's is appended to
  the record it answers under a dated line, and the list of open questions
  in `AGENTS.md` is updated. In files 00 to 37 an "await the owner" may be
  answered in a later file; the list in `AGENTS.md` says what is open now.
- A correction of a record names what was wrong, as the records do.
