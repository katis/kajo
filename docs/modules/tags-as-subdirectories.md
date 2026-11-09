# Tags as subdirectories

The owner's decision of 2026-11-09, when `allInstances` was briefed and the
question "does the current implementation use the `category:` single string
for classes, or `package:`, `tag:` like Pharo?" came up: Kajo had both, a
package that was the file's directory and a `#category : #'Kernel-Collections'`
key in every class definition that repeated the package and added a tag
nobody read but the browser's "by category" view. The owner chose option 2
of three: **the class definition's `#category` key goes entirely; a class's
package is its directory, as before, and its tag, when it has one, is the
subdirectory its file is in** (`kernel/Collections/OrderedCollection.class.st`
is package `Kernel`, tag `Collections`; `kernel/Object.class.st` has no tag).
Nothing about placement lives in the file. Method categories stay as they
are (`{ #category : #accessing }` before each method). Modules 8e (the
Tonel writer and reader in Smalltalk, `ClassDefinition`), 9b (packages and
extension files, the project directory the client writes to) and 9c (the
browser) are what this changes; `docs/modules/live-classes.md`,
`development-protocol.md` and `developer-ui.md` say how they stand.

## Part 1: the model (`kernel/`)

- `ClassDefinition` keeps `package` and gains `tag` (a Symbol or nil);
  `category` and `category:` go, and with them `Smalltalk categoryOf:` and
  `ClassDescription>>category`; `Smalltalk tagOf:` and `packageOf:` are the
  readers. Every class-creation message takes `package:` and
  `package:tag:` in place of `category:`
  (`subclass:instanceVariableNames:classVariableNames:package:`,
  `...package:tag:`, the byte, variable and weak forms alike; `ClassBuilder`
  and primitive 145's Smalltalk side carry the two), and the `category:`
  forms are removed, not kept as a shorthand (open question 1): one way to
  say it, Pharo 12's own templates use `package:`. A class made with no
  package gets the package of the image's default (`Unclassified` today;
  state what it becomes and why) and no tag.
- `DevSession`'s requests: `class.definition` answers `package` and `tag`
  (no `category`), `class.hierarchy` entries carry `tag` beside `package`,
  `class.list` filters by `package` and optionally `tag`, `class.define`
  takes `package` and `tag` (a request with `category` is a malformed
  request, answered as every other one is), `protocol.describe` says so,
  the CLI (`kajo compile`'s `--category` stays, it is the method's) and the
  MCP tools follow from `describe`. `Tests/KajoCompilerTests/DevProtocolTests.swift`
  and the kernel's `DevSessionTest` updated.
- The categories as they stand map to tags by one rule applied once in the
  rewrite: `<Package>-<Rest>` with `<Package>` the file's package gives tag
  `<Rest>` (`Kernel-Tests-Live` is the tag `Tests-Live`; tags may carry
  hyphens, as Pharo's do), a category equal to the package gives no tag,
  and a category without the package prefix is the tag as it is
  (`#SUnit` in `kernel/` becomes `kernel/SUnit/`). List the resulting
  tags of `kernel/` and `tools/` in the doc.

## Part 2: the files (Tonel in Smalltalk and Swift, the scripts)

- The Tonel writer (`TonelWriter`, `Smalltalk writeTonel:`,
  `writePackage:into:`) writes a class file into `<package dir>/<Tag>/`
  when the class has a tag and into the package directory when it has
  none, never writes `#category`, `#package` or `#tag` into the
  definition; an extension file (`<Class>.extension.st`) stays at the
  package's root (the extended class's tag is not the package's business;
  open question 2). The canonical form is otherwise unchanged.
- The Tonel readers, both of them (`TonelReader` in the image and the
  bootstrap `Sources/KajoCompiler/Tonel.swift`, rule for rule, with the
  test that reads every file with both), take the package from the
  directory as now and the tag from the file's subdirectory (one level: a
  file two levels down is a refusal naming the path), accept on load and
  ignore the old `#category` and Pharo's `#package` and `#tag` keys (as
  unknown keys are ignored today; a loaded `#category` does not set the
  tag, the directory does), so a Pharo package or an old Kajo file loads.
  `KernelBuilder.sources(in:)` lists one level of subdirectories; the
  image build, `kajo test --sources`, `kajo run --sources` and the client's
  project directory read them.
- A class whose tag changes from the tools moves its file: the writer
  writes the new file and the old one is removed. Say how a removed
  class's file is handled today and make the moved class's the same; if
  there is no mechanism, add primitive 171 `primRemoveFile:` bounded as
  148 and 149 are (the opened directory, a `.st` file, every path rule of
  "files under the directory the host opened") and use it for both.
- Primitive 148 (`primWriteFile:contents:`) cannot create a directory, so
  a class defined into a new tag has nowhere to go: the write creates the
  one missing directory component (the tag's) when its parent is the
  package directory or a directory under the opened root, with the
  resolution rules the primitive already has (the parent resolved and
  checked inside the root, then `mkdirat` on a descriptor opened
  `O_DIRECTORY | O_NOFOLLOW`; a link in the tag's place is a refusal; a
  tag name is one component with no `/`, `.` or `..`), with tests of the
  refusals beside the existing ones. This is a change under
  `Sources/KajoVM/ObjectModel/`, so the core tier is owed (below).
- `Sources/KajoDev/Project.swift` (9b: the client writes accepted changes
  to `--project` as one file name of the project directory, never a path
  out of it) takes `<Tag>/<Class>.class.st` one level down with the same
  refusals (no `..`, no second `/`, no link followed), creating the tag's
  directory when missing. The generator's templates
  (`Sources/KajoGenerator/Templates.swift`) and every fixture under
  `Tests/KajoCompilerTests/Fixtures/` lose `#category`; a fixture that
  used a category with a tag moves into the subdirectory; `kajo new`'s
  output stays a byte-for-byte fixture. `KAJO_SHELL_CLASSES`'s generated
  image and `apps/Shared/smalltalk` follow.
- `scripts/canonical-tonel.sh` compares the written tree against the
  checked-in one including subdirectories (a file the image did not write
  is reported as stale: a moved class leaves none); `check-tier.sh`'s
  Smalltalk tier matches `kernel/` and `tools/` by prefix and needs no
  change (say so from a `--dry-run`).
- **The rewrite of `kernel/` and `tools/`** is one commit of its own, made
  by the image (`Smalltalk writeTonel:` after the writer change, with the
  files moved by plain `mv`, never `git mv`, and added by name): every
  class file in its tag's subdirectory, no `#category` key anywhere, the
  method categories untouched, checked by the round trip on the new tree
  (`canonical-tonel.sh --check` rc 0) and by the compiler test that
  compares both readers on every file; `git diff -M --stat` of that commit
  shows renames with a one-line change each. AGENTS.md's structure section
  is the main session's to update.

## Part 3: the browser (`tools/`)

- `BrowserModel`'s "by category" grouping becomes "by tag": the package
  pane as now, and the class outline either by superclass (unchanged) or
  grouped by tag (a tag is a parent row, classes with no tag at the
  root); the browser's toggle names them. A class's tag is shown in the
  definition pane (the class definition the browser prints uses the new
  `package:tag:` message). `BrowserModelTest` and `BrowserWindow`'s tests
  against `FakeDevClient` updated; `class.hierarchy`'s `tag` field is
  what they read.
- Defining a class from the browser into a package and a tag (the
  definition pane's `package: #Foo tag: #Bar`) writes the file into
  `<project>/Bar/` through the client; tested end to end in the scripted
  session's define step if it defines a class, else in `tools/`'s tests
  against the fake.

## Bar

- `kernel/` and `tools/` are rewritten in one commit with every class in
  its tag's subdirectory and no `#category` key; `canonical-tonel.sh
  --check` rc 0 on it and on every later commit; both Tonel readers agree
  on every file; the image build, the development image, the kernel tests
  (228 plus the new ones) and the tools' tests pass headless, in the Mac
  shell's tests mode and on the iPhone.
- A Pharo-style file with `#package`/`#tag` keys and an old Kajo file
  with `#category` both load (a fixture each), take their tag from the
  directory, and the next write leaves the keys out.
- From the tools against the development image: define a class into a
  new tag, see its file appear in `<Tag>/`, change its tag, see the file
  move (old gone, new present), with the round trip clean afterwards;
  `kajo new`'s sample project builds and `just new-check` passes.
- Primitive 148's new directory creation refuses a link in the tag's
  place, a two-level path, `..`, and a path out of the root, each with a
  test; `ExtremeIntegerTests` needs nothing new (no integer argument)
  unless 171 takes one.
- `protocol.describe` lists the new fields; `kajo browse` and the MCP
  tools show `package` and `tag`.
- The gates: `just check` on the final code commit picks the core tier
  (primitive 148 changes under `ObjectModel/`), every gate; `interpret`
  unchanged (`just arc-check`, the disassembly diff), the aligned A/B
  within noise (nothing on the hot path changes; the A/B is the tier's
  rule).

## Open questions for the owner (build the recommended option, list them)

1. Should the `category:` class-creation messages stay as a shorthand that
   splits `'Package-Tag'` at the first hyphen, for pasting older Pharo
   class definitions? Recommended: no; one way to say it (`package:` and
   `package:tag:`), and Pharo 12's own templates use `package:`.
2. Should an extension file be placed in a tag's subdirectory when the
   extending methods' category names one (Pharo puts `*Package-Tag`
   method categories to use this way)? Recommended: no; extension files
   stay at the package's root, a method's category is the method's.
3. Should a class with no tag be allowed at all, or should every class
   have one (Pharo allows none)? Recommended: allowed, at the package's
   root; the kernel's `Object`, `Boolean` and the like read better there
   than under an invented tag.
