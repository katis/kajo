# Tags as subdirectories

Tags as subdirectories, built 2026-11-09
(`docs/modules/tags-as-subdirectories.md`, the owner's choice of the same
day over Pharo's `package:`/`tag:` keys in the file: the class definition's
`#category` key goes entirely): a class's package is its directory as before
and its tag, when it has one, is the one subdirectory its file is in
(`kernel/Collections/OrderedCollection.class.st`), nothing about placement
in the file, method categories unchanged; `ClassDefinition` keeps `package`
and gains `tag`, `category`, `Smalltalk categoryOf:` and
`ClassDescription>>category` are gone, `Smalltalk tagOf:` and `tagsOf:` are
new, every class-creation message takes `package:` or `package:tag:` (the
`category:` forms removed, no shorthand; a class made with no package goes
to the session's package or to `Unclassified` outside one, `ClassBuilder
defaultPackage`; a class with no tag sits at the package's root); both Tonel
readers ignore `#category`, `#package` and `#tag` (a Pharo-style and an
old-Kajo fixture load and are written back without them) and take the tag
from the file's path one level down, a deeper file refused by path,
`KernelBuild.sources(in:)` listing one level of subdirectories; the writer
writes a tagged class into `<dir>/<Tag>/` and extension files at the
package's root; primitive 148 creates the one missing directory with
`mkdirat` on an `O_DIRECTORY | O_NOFOLLOW` descriptor of the resolved parent
and refuses a link in the tag's place (dangling or not, even one leading
inside), two missing components, `.`, `..` and a path out of the root, each
refusal tested (46 lines, 3 `unsafe`, the only change under
`Sources/KajoVM`); no primitive 171: a moved class's old file goes as a
removed class's does, a `{path, remove}` entry the client applies, and
`ProjectWriter` takes `<Tag>/<Class>.class.st`, creates a missing tag
directory and removes one whose last file goes; the protocol's
`class.definition` and `class.hierarchy` answer `package` and `tag`,
`class.list` and `class.define` take them (a `category` argument is the
usual malformed reply; a define that changes a class's place answers the
file to write and the one to remove), `class.categories` became
`package.tags`; the browser's outline is by superclass or by tag (a toolbar
toggle) and its definition pane shows `package:` and `tag:`; the generator's
templates, the fixtures, `apps/Shared` and `gen-classes.py` (50 tag
directories) follow, `canonical-tonel.sh` walks subdirectories and reports
stale files; the rewrite of `kernel/` and `tools/` is one commit of renames
by the image's writer (43c948a, 207 entries, 202 insertions and 406
deletions: 201 renames whose change is the key's line or that line and the
comma before it, three five-line files pairing only at `-M30%`; a commit
before it, 6148a24, put seven hand-edited files into the image's order at
their old paths so the rewrite is pure), the rule `<Package>-<Rest>` to
`<Rest>` giving `kernel/` 15 tags (Classes, Collections, Compiler,
Development, Exceptions, Methods, Numbers, Objects, Processes, SUnit,
Streams, System, Tests, Text, UI; every kernel category had a tag, so
nothing but README at the root, `Object` in `Objects/`) and `tools/` four
(Client, Models, Tests, Windows), the round trip rc 0 on the rewrite commit
and on the final code commit and both readers agreeing on all 175 files and
183 tested paths; from the tools against the development image in a test
shell a class accepted with `package: #Tools tag: #Probes` appears as
`Probes/ToolsTagProbe.class.st`, re-accepted with `tag: #Moved` it moves and
`Probes/` goes, removed the project copy is byte-identical to `tools/`; the
gates found a kernel race as old as 8b (`Smalltalk rebuildClassNames`
published an empty table and then filled it, so a request Process looking a
class up during another's rebuild missed `Object` under load; the table is
built in a temporary and published whole, 211a6ee) and the tools harness
waits 120 s for the protocol's start; `interpret` identical (1817 lines
each), `just arc-check` passing, the aligned A/B against 9a9f02e 0.994 to
1.007 at 1 worker with instruction ratios 1.000 and 0.935 to 1.064 at 8 (the
usual 8-worker spread); `just check 9a9f02e` on 211a6ee, the core tier,
every gate in 12 558 s (408 + 123 tests, ThreadSanitizer 0 reports alone and
under load, 230 kernel tests headless, in the Mac shell and on the iPhone,
the four fuzzers with "libFuzzer build: ok" at 0.82 to 3.35 million runs,
the Mac matrix's ring under `young=stw` 168 to 191 frames behind 8 to 9
fallbacks and every other row 0, the iPhone 0 fallbacks and 1 and 4 frames
in the same row; a first run on aae5c35 failed `swift-test-load` on the race
and `tsan` on the 30 s wait, both fixed in 211a6ee); not done: the fuzz
seeds, the bench fixtures and the experiments keep `#category` (read and
ignored), `kajo browse` has no `--package` filter, the iPad; its three
questions built as recommended (no `category:` shorthand, extension files at
the root, untagged classes allowed) and answered so by the owner on
2026-11-10.
