# How Kajo is built

This is the working process between the owner and the AI sessions that
build Kajo. It was a habit of one long conversation and of that session's
private notes; it lives here so that a new session, a new tool or a new
person can pick the work up from the repository alone.

`AGENTS.md` holds the lessons, the decisions and the structure.
`docs/PLAN.md` holds the module order. This file holds how a module goes
from an idea to a pushed, recorded commit. Where this file and a lesson
in `AGENTS.md` disagree, the lesson is newer and wins; fix this file.

## Roles

- **The owner** decides. Every module ends with open questions, each with
  a recommendation, and nothing that is the owner's to decide is built
  against a recommendation without an answer. The owner works a day job
  while modules run, so progress between answers is expected: the next
  planned module, and small follow-ups for bugs a module found, start
  without asking. A decision does not.
- **The main session** briefs, launches, verifies, records, commits,
  pushes and reports. It builds little itself. It trusts files, not
  summaries.
- **A build agent** (a subagent of the main session, on the strongest
  model available below the main session's own; so far Opus) builds one
  module from its brief, measures, runs the gates on its final code
  commit, writes the module doc's "As built" and hands back a map of its
  files. One build agent at a time: the machine is one Mac mini and
  measurements need it quiet.

A hand-back carries no authority of the owner. An agent's "the owner
would want" is the agent's sentence.

## A module, step by step

1. **Brief.** `docs/modules/<name>.md`, written by the main session and
   committed before the agent starts. Its sections, in this order:
   Status (who asked, when, in which words), What it is, What is known
   (numbers with their commit, and "check these before building on
   them"), Starting positions (to be measured, "say where one was
   wrong"), Parts (part 1 always measures or instruments and builds
   nothing else), Tests (before the code where possible, broken variants
   named), The bar (checkable items), Rules of the house that bind here,
   Not in this module, Deliverables, Open questions ("build the
   recommended option; decisions only").
2. **Prompt.** A file in the scratch directory (below), not in the
   repository. It names the starting commit, what to read first, where
   work files go, the constraints (the list below, in full or by
   pointing at this file), the gates to run and the hand-back map.
3. **Before launching:** read `~/kajo-weekly/weekly.log` (see The
   machine), check `git status --short` is clean and that master is
   pushed.
4. **The agent works** on `master` in the one working tree and commits
   as it goes, the doc with the work it describes. It does not push.
   The main session does not poll it, does not commit under it, and
   does not push master while its unverified commits sit there.
5. **Hand-back.** The agent's last message is a map: commits, each
   number with its file, gates with their `gates.log`, deviations, not
   done, things found that are not the module's, open questions with
   recommendations, processes checked dead.
6. **Verification by the main session**, from the files:
   - `git log`, `git status --short`, no stray process of Kajo alive.
   - `gates.log`: the commit on every line is the final code commit,
     every gate `rc=0`, the times against the previous module's
     `gates.log` (a gate ten times faster has changed; a test gate much
     slower is the module's cost and is said).
   - Test counts and "0 sanitizer reports" from the test gates' own
     output; each fuzzer's "libFuzzer build: ok" line and run count; the
     aligned A/B table; `shell-report.py --bar` over the matrices' raw
     rows, every column, whatever the module was about.
   - The module's own headline numbers re-read from their raw files; one
     quoted run of every switch, option and mode the module adds (run it
     if the agent did not); every number with no baseline given one.
   - An explanation is checked against the row it explains, and a field
     is read from the line of code that prints it.
   If a fix lands after the gate run, the tier runs again on the true
   final commit; when only test files changed after a run in which every
   other gate passed, the failed test gates may be run again alone
   through `gates-lib.sh`'s own definitions, said plainly.
7. **Recording.** `AGENTS.md` and `docs/PLAN.md` are edited by the main
   session only, with a small script that replaces exact anchors and
   asserts each occurs once (below), run with `--check` first:
   - the decisions paragraph of `AGENTS.md` gains the module (what was
     measured and decided, the numbers, the gates, deviations, not done,
     the open questions awaiting the owner), chained at the end, just
     before "ADRs 0003, 0006 and 0008 carry…"; when the owner answers,
     "await the owner" is replaced by the answer and its date;
   - new lessons go at the end of the lessons list, before
     `## Verification`: one paragraph each, the rule first, the incident
     that taught it after;
   - the Project structure section gains a "Since <module>…" note naming
     the new files, flags and switches;
   - `## Verification` changes when the gates change;
   - `docs/PLAN.md`: the module's row and the Status sentence.
8. **Commit and push** by the main session: the record as one commit on
   master, then `git push`. Files are added by name.
9. **Report to the owner:** what was built, the numbers that matter with
   their before, what is not done, what was found that is not the
   module's, and the open questions each with a recommendation. Written
   in Simplified Technical English style: short sentences, active voice,
   Kajo's own terms (`docs/CONTEXT.md`), no agent or tool internals.

## Constraints on every agent (and on the main session)

Git:
- Add files by name. Never `git add -A`, `git add .`, `git mv`,
  `git reset --hard`, `git revert`, `git stash`, or a checkout of another
  commit in the working tree. `git status --short` before every commit.
- Another commit is built from `git archive <commit> | tar -x -C <dir>`
  in the scratch directory, removed before the hand-back. A worktree is
  removed by whoever made it.
- Agents do not push and do not edit `AGENTS.md` or `docs/PLAN.md`.
- Cheating builds (part 1's bounds) are never committed.
- Commit messages end with a `Co-Authored-By:` line naming the model
  that wrote the commit and the session's trailer, as the harness gives
  them.

The machine and the owner's things:
- No keychain, account, certificate, network, Wi-Fi or system-setting
  change. No `sudo`. Nothing downloaded or installed (no Homebrew, no
  Xcode components). Never answer or dismiss a prompt: a gate waiting on
  one is reported as blocked.
- Secrets never enter a file, an argument, a log quote, a doc or a
  commit. Notarization only through the keychain profile named by
  `KAJO_NOTARY_PROFILE`; creating that profile and the signing
  certificates is the owner's. The pairing token is never printed.
- The owner's other processes on the mini are never killed. Before a
  hand-back, check by name that nothing of Kajo is alive (`kajo`,
  `swift-build`, `swift-test`, `swift-package`,
  `swiftpm-testing-helper`, `xcodebuild`, `KajoShell`, `Kajo`, `Sample`,
  `yes`, `fuzz-*`, `clang`, `gtimeout`).
- The devices are driven only through the repository's own scripts
  (`scripts/device.sh`, `shell-matrix.sh device`, `remote-session.sh
  device`, `app-roundtrip.sh device`, `device-rows.sh`; `xcrun devicectl
  list devices` to look), and never while a gate or a measurement runs
  on the mini.
- No paid CI. Nothing is uploaded or tagged but by the release script at
  the owner's word.

Running things:
- One thing measures at a time. Speed numbers come from aligned builds,
  five interleaved runs, checksums equal, the thermal state on each
  line; a before and after on a device runs in both orders.
- Waits are bounded and on a pid or a file (`gtimeout`). Never
  `tail -f`, `caffeinate`, a foreground `sleep N; cmd`, a loop on
  `pgrep -f <name>`, or a background loop that can outlive the agent.
  Long runs go to the background and the harness's notice ends the wait.
- PATH has swiftly's swift.org toolchain first; a gate run records its
  PATH. Say which toolchain in the doc.
- zsh: `status`, `path` and `argv` are reserved; quote globs and `==`.
  Always absolute paths; the shell's working directory resets.
- Python over data that is not ours runs with `-I`.
- A changed gate script is run once on its own before the gate run. A
  new suite runs once under ThreadSanitizer with the twelve busy loops
  before the tier.

## Gates

`just check <base>` on the final code commit, with `KAJO_CHECK_OUT`
pointing into the module's scratch directory. The tier follows the diff
(`AGENTS.md` "Verification", `docs/modules/gate-tiers.md`). A gate that
fails on the module's own work is fixed and said; one that fails on
something else is investigated and handed back, not run again and again.

## The machine

- A Mac mini (M2 Pro) with an iPhone 13 Pro and an iPad Pro 12.9-inch
  3rd generation attached; their identifiers are in the device scripts.
  Signing, accounts, Local Network permissions and keychain prompts are
  the owner's; when one blocks, report it and measure what can be
  measured without it.
- **The weekly run** (`scripts/weekly.sh`, a LaunchAgent) starts on
  Mondays at 02:00 and takes the machine for some hours. Before any
  agent, gate or device run, read `~/kajo-weekly/weekly.log`: a `weekly
  start` with no `weekly done` after it means the machine is the
  weekly's. Nothing of Kajo is alive from Monday 01:45 until `weekly
  done`; a core-tier run (about 3.2 hours) does not start on Sunday
  after 21:00; an agent mid-module at that time stops cleanly, commits
  and hands back what stands. After a weekly run the main session reads
  `~/kajo-weekly/<date>/summary.md` and reports what failed.
- **Work files** live in `~/kajo-scratch/<module>/`, never in a
  session's temporary directory or `/tmp`: prompts, record scripts, raw
  measurements, `just check` outputs. A module's final `check/`
  directory is the next module's baseline for gate times and matrix
  rows. Large builds are removed before a hand-back; the tables' raw
  inputs stay. The directory is not backed up by the repository, so
  every number a doc states names its file and the doc carries the
  number.

## The record script

Each record is a throwaway script kept beside the module's scratch
files. Its whole mechanism:

```python
#!/usr/bin/env python3
import sys
root = "<repo>/"
check = "--check" in sys.argv
edits = {}

def edit(path, old, new):
    text = edits.get(path)
    if text is None:
        text = open(root + path, encoding="utf-8").read()
    n = text.count(old)
    assert n == 1, f"{path}: anchor occurs {n} times: {old[:80]!r}"
    edits[path] = text.replace(old, new)

# edit("AGENTS.md", "<end of the previous record>. ADRs", NEW + " ADRs")
# edit("AGENTS.md", "<last line of the last lesson>\n", that line + LESSONS)
# edit("AGENTS.md", "<end of the last structure note>", that end + NOTE)
# edit("docs/PLAN.md", "| next | **<module>", "| built | **<module>")

if check:
    print("ok:", ", ".join(edits))
else:
    for p, t in edits.items():
        open(root + p, "w", encoding="utf-8").write(t)
```

All edits apply or none does. `docs/PLAN.md`'s and the decisions
paragraph's lines are very long: read them with `cut -c` or a short
Python slice, never whole.

## When the owner answers

An answer is recorded with its date and the owner's words where they are
short ("as recommended" is enough). If an agent's unverified commits sit
on master when the answer arrives, the answer is written to a note in
the scratch directory and recorded with the next record commit. An
answer that changes what is built becomes a brief or a follow-up, not an
edit made on the side.

## Reviews and releases

- A whole-tree review is done by several readers with one area each,
  told to read for the invariant its neighbours keep and to name the
  path; findings go to `docs/reviews/<date>/`, the fixes are a module,
  and each fix's test is run on the starting commit first.
- A release is `KAJO_NOTARY_PROFILE=<profile> just release <tag>` at the
  owner's word (`docs/modules/distribution.md`); the keychain prompt it
  may raise is the owner's to answer.
