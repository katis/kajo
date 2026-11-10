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

## As built (2026-11-09)

Commits: 923dc3c (the code: Swift, kernel, tools, fixtures, scripts),
6148a24 (the kernel and tools files that commit edited by hand, put in the
image's own order with `#category` still in place, so the rewrite is pure
renames), 43c948a (**the rewrite**), aae5c35 (the tools' end-to-end test),
211a6ee (a race in the kernel's class-name table the gates found, and a
harness bound), then this doc. The build of the recommended option of each open question is
below.

### Every reader and writer of a class's category, and what it became

Found by grepping the tree for `category` and `#category` (method
categories, `{ #category : ... }`, `compile:classified:`, `categoryOf:`
on a Behavior, `method.compile`'s `category` and `kajo compile --category`
are the method's and stay as they were).

| Where | Before | Now |
|---|---|---|
| `ClassDefinition` | ivar `category`, `category`, `category:`, `instVarNames:classInstVarNames:category:kind:comment:` | ivar `tag` (a Symbol or nil, empty is nil), `tag`, `tag:`, `instVarNames:classInstVarNames:package:tag:kind:comment:`; `package` as before |
| `ClassDescription>>category`, `category:` | read and set the definition's category | removed (`OrganizationTest` asserts it) |
| `Smalltalk categoryOf:` | the category as a String | removed; `Smalltalk tagOf:` (Symbol or nil), `tagsOf:` (a package's tags, sorted), `packageOf:` as before |
| `Smalltalk recordDefinitions:` | field 5 the category | field 5 the tag (empty for none) |
| `KernelBuilder.swift` `Plan.definitionRecords` | the file's `#category` | the tag from the file's place (`KernelBuild.sources(in:)` answers `(file, text, tag)`; `package(ofFile:tag:)` looks one directory up for a tagged file) |
| `Tonel.swift` `TonelClass.category` | read from the definition | gone; `#category`, `#package`, `#tag` read and ignored; `tonelTag(ofPath:)`, `isTonelTag` |
| `TonelReader>>readDocument` | `doc category:` | the key ignored; `TonelReader class>>tagOfPath:` |
| `TonelDocument` | ivar `category`, in `summary` | gone from both |
| `TonelLoader class>>load:` | passed the file's category | `load:` keeps an existing class's place, `load:package:tag:`, `load:path:` (the tag from the path); `Smalltalk readTonel:path:` |
| `TonelWriter class>>headerOf:` | wrote `#category` (default `#Unclassified`) | never writes `#category`, `#package` or `#tag`; `pathOf:package:` answers `<Tag>/<Name>.class.st`; `write:package:into:` writes there |
| `ClassBuilder define:...category:...`, `newClass:...category:...` | category (default `#Unclassified`), `c category:` on a redefinition | `define:...package:tag:kind:comment:`: a package given places the class with that tag, none keeps an existing class's place; `place:package:tag:`, `checkTag:`, `defaultPackage` |
| `Class` creation messages | `subclass:...category:`, `...category:kind:`, `byteSubclass:`, `variableSubclass:`, `weakSubclass:` with `category:`; `...package:` mapped to the category | `...package:` and `...package:tag:` for each, `...package:tag:kind:`; every `category:` form removed (question 1) |
| `DevSession classCategories` (`class.categories`) | the categories | removed; `packageTags:` (`package.tags`) |
| `DevSession classDefinition:` | `category` | `package`, `tag` |
| `DevSession classHierarchy` | `category` per entry | `tag` per entry beside `package` |
| `DevSession classList:` | filter by category | `classList:tag:`, by package and optionally tag |
| `DevSession classDefine:...category:` | category, the session's package | `...package:tag:`; files: the new one and the old one to remove when the place changed (`filesFor:movedFrom:`); the ivar `package` renamed `sessionPackage` (an argument may not shadow it) |
| `DevClient` | `classCategories:`, `classDefine:...category:then:`, `classList:then:`, `requests` | `packageTags:then:`, `classDefine:...package:tag:then:`, `classList:tag:then:`, the map updated |
| `BrowserModel` | `byCategory`, the outline by category, `parseDefinition:`/`definitionText:`/`newClassTemplate` with `category:` | `byTag`, `toggleByTag`, the outline grouped by tag; `package:` and `tag:` in the pane; a `category:` definition refused naming the new form |
| `BrowserWindow` | toolbar "Hierarchy/Category" | "Hierarchy/Tag" |
| Kernel tests | `LiveClassTest`, `OrganizationTest`, `ReflectionTest`, `DevelopmentTest`, `TonelTest` | rewritten for package and tag; new `DevelopmentTest>>testClassDefineIntoATagAndMoving`, `TonelTest>>testATagIsTheFilesDirectory` |
| Tools tests | `BrowserModelTest`, `DevClientTest`, `TargetPickerModelTest` | by tag, `package.tags` |
| Swift tests | `Support.tonel()` (`#category : #Test`), `KernelImageTests`' inline files, `swiftSummary`, `DevProtocolTests`, `AgentInterfaceTests` | no key; summaries without it; requests with `package`/`tag` |
| `Templates.swift` | `#category : #<Name>` in both files | removed (fixture `app-project` byte for byte) |
| `scripts/gen-classes.py` | `#category : #'Generated-<k>'` | the file in `<dir>/<k>/` |
| Fixtures | 14 files under `Tests/KajoCompilerTests/Fixtures/`, 5 in `apps/Shared/smalltalk`, 1 in `apps/Shared/devsession`, two `category:` sends in fixture methods | key removed, moved by the rule (below), sends `package:tag:` |
| Not changed | `Tests/KajoVMTests/Fixtures/fuzz/syntax` (10 seed files), `Tests/KajoVMTests/Fixtures/smalltalk/{ivars,sends}` (5), `experiments/runtime-comparison/programs` (5) | they keep the key; both readers ignore it, so they are old-Kajo files that load (the seeds keep exercising that path; experiments are evidence) |

### The rule and the resulting tags

Applied once by a script to each file's `#category` (in `kernel/` and
`tools/` only to move the files; the image wrote their content):
`<Package>-<Rest>` is the tag `<Rest>`, the package's own name is no
tag, anything else is the tag as it is.

- `kernel/` (package `Kernel`): `Classes` 7, `Collections` 14,
  `Compiler` 18, `Development` 9, `Exceptions` 19, `Methods` 7, `Numbers`
  9, `Objects` 5, `Processes` 9, `SUnit` 5, `Streams` 4, `System` 6,
  `Tests` 44, `Text` 4, `UI` 14: 174 classes, none at the root (every
  kernel category had a tag; `kernel/README.md` is the root's one file).
  So `Object` is `kernel/Objects/Object.class.st`, not at the root as the
  brief's example had it: the rule decides.
- `tools/` (package `Tools`): `Client` 2, `Models` 8, `Tests` 10,
  `Windows` 10.
- Fixtures: `project/Core/` (Sample), `answers/Tests/`, `snapshot/Tests/`,
  `shell/Tests/`, `tonel/Tests-Tonel/`, `measure/Tests-Measure/`;
  `toolsprobe/`, `app-project/Sample/src/` and `apps/Shared/devsession`
  at their roots; `apps/Shared/smalltalk/Shell-Bench/` and `Shell-Demo/`.

### Readers and writer

Both readers ignore the definition's `#category`, `#package` and `#tag`
like any unknown key; the tag comes from the path relative to the
package's directory, by one rule in each (`tonelTag(ofPath:)`,
`TonelReader class>>tagOfPath:`): one component is no tag, two are the
first as tag (refused when empty or hidden), more are refused naming the
path. `KernelBuild.sources(in:)` lists the directory's files and one level
of subdirectories (hidden entries skipped), refusing a `.st` file found
further down; files sorted by relative path. The image build, `kajo
build-image`, `kajo test`, `kajo run --sources` and the client's project
read the same way, since all go through it. `TonelRoundTripTests` reads
every kernel file and the Tonel fixture with both readers (175 files,
summaries identical) and compares the tag rule on all their paths plus
eight made-up ones (183 paths, no disagreement; `readers.txt`).

The writer writes a tagged class's file into `<dir>/<Tag>/` and never a
placement key; an extension file stays at the package's root (question 2).
A class with no tag is at the root (question 3).

A loaded file never sets the tag from a key: `Smalltalk readTonel:` keeps
an existing class's place (a new one gets the session's package or the
default and no tag), `readTonel:path:` takes the tag from the path.

The default package (a class made with none named, outside a development
session) is `Unclassified` (`ClassBuilder defaultPackage`): it was the
category such a class got and the package was nil, so the writer had no
directory for it and the browser no package to list it under; now every
class has a package.

### Moving a class's file

Today's removal: `class.remove` answers `{path, remove: true}` and the
client's `ProjectWriter` deletes the file. A move is the same: when
`class.define` changes a class's tag or package, the answer's `files` are
the new file to write and the old path to remove, in that order. So
primitive 171 was not needed and is not built. `ProjectWriter` removes a
tag's directory when its last file goes.

### Primitive 148 creates the tag's directory

`sourcesPath(_:_:creatingDirectory:)` (only 148 passes true, after its
arguments are checked): when the file's directory does not resolve and is
the one missing component, its parent must resolve inside the opened root,
and it is made with `mkdirat` on a descriptor of the resolved parent opened
`O_RDONLY | O_DIRECTORY | O_NOFOLLOW`; anything in its place (a dangling
link: an existing link resolves) fails `mkdirat` and refuses the write. A
write whose own directory (below the root) exists as a symbolic link is
refused whatever it names. The name rules are the primitive's (no empty,
`.` or `..` component, no NUL, not absolute). Tests in
`LiveClassTests.theFilePrimitivesStayInTheirDirectory`: `none/x` and
`sub/Tag/T.class.st` now create their directory (the first was a refusal
before); refused: `new1/new2/T.class.st` (two missing, `new1` not created),
`dangling/T.class.st` (a dangling link in the tag's place, the link
untouched), `sublink/T.class.st` (a link to `sub`, inside the root),
`out/NewTag/T.class.st` (out of the root through a link, nothing created
outside), `Tag/../T.class.st`, `Tag/./T.class.st`, a non-String contents
(no directory made), and a read of `Unread/T.class.st` (reads never
create). 46 lines added, 3 with `unsafe` (`lstat`, `open`, `mkdirat`).
`ExtremeIntegerTests` needs nothing: no integer argument.

### The project writer

`ProjectWriter.isSourceFileName` takes a class or extension file name at
the root or `<Tag>/<Name>.class.st` (the tag one non-hidden component, no
NUL or backslash; an extension file in a tag is refused). A tag's
directory that is a link is refused, never followed; a missing one is
created; a link in a file's place is removed before the write. Tested in
`DevProtocolTests.changesAreInstalledMarkedAndWrittenToTheProject`
(`a/b/c.class.st`, `../a/b.class.st`, `./b.class.st`, `a//b.class.st`,
`.hidden/b.class.st`, `a/b.extension.st`, `a/..`, `/a/b.class.st`, and a
tag's directory linked outside, which stays empty).

### The protocol

`protocol.describe` lists `class.define` with `name superclass
instanceVariables classVariables package tag`, `class.list` with `package
tag`, `package.tags` with `name`, and no `class.categories`;
`class.definition` and `class.hierarchy` answer `package` and `tag`. A
`class.define` with `category` is answered "class.define has no argument
category (its arguments: ...)". The MCP tools follow (`class_define`'s
schema has `package` and `tag`, `package_tags` exists, asserted in
`AgentInterfaceTests`); `kajo browse <Class>` prints the definition with
both. A `class.define` of an existing class with neither keeps its place;
with a tag only, the session's package.

### The browser

The class outline is by superclass or grouped by tag (each tag a parent
row, its classes under it, classes with no tag at the root after the
tags); the toolbar names the toggle "Hierarchy/Tag". The definition pane
reads `Super subclass: #Name instanceVariableNames: '...'
classVariableNames: '...' package: #P` and `tag: #T` on a line of its own
when the class has one; the new-class template says `package: #<the
selected package>`. Accepting sends `package` and `tag`; a definition
with `category:` is refused in the status line naming the new form.
`BrowserModelTest` covers the tree by tag, the pane, accepting into a
tag and back to the root, and the refusal, against the fake. The scripted
session defines no class, so the end-to-end define is
`ToolsTests.aClassDefinedIntoATagFromTheBrowserMovesWithItsTag`: the
development image in a test shell, the tools on its own socket as the
developer in package Tools, the project a copy of `tools/`; the browser
defines `ToolsTagProbe` with `tag: #Probes` (the file appears in
`Probes/`), again with `tag: #Moved` (`Moved/` has it, `Probes/` is gone),
then removes it (`Moved/` gone, the copy byte for byte `tools/`). The
listings are in `toolsrun/`.

### The rewrite commit

43c948a, made by moving each file with a plain `mv` by the rule and then
running `scripts/canonical-tonel.sh` (a development image built from the
moved tree writes `Kernel` into `kernel` and `Tools` into `tools`; it
copied all 204 files back); `canonical-tonel.sh --check` answered rc 0
before the commit, and all 230 kernel tests, `ToolsTests` and
`TonelRoundTripTests` passed on the tree. Old paths removed and new ones
added by name. `git diff -M --stat`: 207 entries, 201 renames whose change
is the key's line going (11 files, where `#type` followed it) or that line
and the comma before it (190, three lines), and three five-line files
(`AssertionFailure`, `IllegalResumeAttempt`, `PrimitiveFailed`) that git
pairs only at `-M30%`, each the same three-line change; 202 insertions,
406 deletions. To get pure renames, 6148a24 first wrote the seven files
923dc3c had edited by hand in the order the image writes them, at their
old paths with the key in place (a sort of methods and one blank line, no
change of content).

`scripts/canonical-tonel.sh` now walks one level of subdirectories both
ways: a written file that differs or is missing is listed (and copied), a
checked-in `.st` file the image did not write is listed as `stale:` (and
removed with its emptied directory). `check-tier.sh` needs no change: its
Smalltalk tier matches `kernel/*` and `tools/*` by prefix
(`--dry-run --paths -` with `kernel/Collections/Array.class.st` and
`tools/Models/BrowserModel.class.st` picks `smalltalk`), and
`check-tier-test.sh` passes its 36 checks.

### The bar

- **The rewrite.** 43c948a: every class file of `kernel/` and `tools/` in
  its tag's subdirectory, no `#category` key in any class definition (the
  only `\t#category :` line left is inside `TonelTest`'s string of an
  old-Kajo file); `canonical-tonel.sh --check` rc 0 on it and on the final
  code commit 211a6ee (`roundtrip/`); both readers agree on every file
  (175 files, 183 paths; `readers.txt`). The image build, the development
  image and the tests: the kernel tests 230 of 230 headless (228 before,
  plus `testClassDefineIntoATagAndMoving` and `testATagIsTheFilesDirectory`),
  in the Mac shell's tests mode (230 of 230 in 9.1 s, the development
  image, thermal nominal) and on the iPhone 13 Pro (230 of 230 in 5.3 s,
  thermal nominal; `iphone/`); the tools' tests pass in
  `ToolsTests.theDevelopmentImageBuildsAndTheToolsTestsPass`; the whole
  `swift test` 408 + 122 before the gates.
- **Old files load.** `Fixtures/legacy/Shapes/LegacyPharo.class.st`
  (`#package : #'Elsewhere'`, `#tag : #'Wrong'`) and
  `Fixtures/legacy/Old/LegacyKajo.class.st` (`#category :
  #'Legacy-Wrong'`) build with the kernel, are package `Legacy` with tags
  `Shapes` and `Old`, and `writePackages:` writes them back to the same
  paths with the keys gone and nothing else changed
  (`TonelRoundTripTests.pharoAndOldKajoFilesLoadAndTheNextWriteLeavesTheKeysOut`);
  the image's own reader the same in `TonelTest>>testATagIsTheFilesDirectory`
  (`readTonel:path:`).
- **From the tools.** Define into a new tag, the file in `Probes/`;
  change the tag, the file in `Moved/` and `Probes/` gone; afterwards the
  project (a copy of `tools/`) is `tools/` byte for byte, and
  `canonical-tonel.sh --check` on the repository is rc 0 (`toolsrun/`).
  This ran against the development image in a test shell (`LocalTools`),
  not in the Mac app's window: the same image, tools and client host, with
  ToolsProbe acting as the user. `just new-check` passes (`new-check: ok`;
  the generated project's four products and the simulator Debug build with
  0 warnings, the Release binaries without the development half, the image
  phase 0.12 to 0.13 s).
- **Primitive 148's refusals**: a link in the tag's place (dangling, and
  one to a directory inside the root), a two-level path, `..`, `.`, and a
  path out of the root, each in `theFilePrimitivesStayInTheirDirectory`.
  No integer argument, so nothing for `ExtremeIntegerTests`.
- **`protocol.describe`** lists `package` and `tag` for `class.define` and
  `class.list` and the new `package.tags`; the MCP tools follow; `kajo
  browse <Class>` answers `class.definition`, which carries both.
- **`interpret`.** `just arc-check` passes (`arc-check.txt`). `interpret`
  in `Dispatch.o` of the aligned `-enable-testing` builds of 9a9f02e and
  aae5c35 is identical (211a6ee changes a kernel method and a test only), 1817 lines each, the diff empty, addresses
  included (`interpret.diff`).
- **The aligned A/B** against 9a9f02e (`scripts/ab.sh`, 5 interleaved
  runs, checksums the same everywhere; `ab/`): 0.994 to 1.007 at 1 worker
  with instruction ratios 1.000; 0.935 to 1.064 at 8 workers with
  overlapping ranges for every kernel but `storeheavy` (274.3 ms, 271 to
  282, against 291.8, 274 to 300) and instruction ratios 0.998 to 1.001,
  cycle ratios 0.988 to 1.014: the 8-worker spread of earlier modules
  (the interpreter is identical and nothing on a hot path changed; the
  Smalltalk kernels are built from the changed kernel).

### The gates

`just check 9a9f02e` on 211a6ee picked the core tier, chosen by
`Sources/KajoVM/ObjectModel/LiveClasses.swift` (primitive 148), 245 files
in the diff; every gate passed in 12 558 s on swift.org 6.4.2 (the
toolchain first on PATH): 408 + 123 tests in every test gate,
ThreadSanitizer 0 reports alone and under twelve busy loops, 230 kernel
tests, the four fuzzers with "libFuzzer build: ok" (kasm 2.23, snapshot
3.35, syntax 0.82, protocol 1.58 million runs), `apps`, `new-check`, the
A/B; the Mac matrix's warm-up 0 of 1200 and every row 0 frames but the
ring under `young=stw` (168, 187, 191 frames behind 8, 9, 9 counted
soft-limit fallbacks, longest stop a 199 to 211 ms compacting full
collection, as before) and the hog with the budget off (by design); the
iPhone's warm-up 0 of 1200, 0 fallbacks, the same ring row 1 and 4 frames
behind 14.1 and 14.6 ms scavenges, every other row but the hog 0.

    2026-11-09 22:39:59 211a6ee check-tier core: 245 files from 9a9f02e...HEAD (9a9f02e...211a6ee) and the working tree
    2026-11-09 22:39:59 211a6ee start clean-build (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-09 22:40:21 211a6ee end clean-build rc=0 22s
    2026-11-09 22:40:21 211a6ee start swift-test (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-09 22:47:16 211a6ee end swift-test rc=0 415s
    2026-11-09 22:47:16 211a6ee start swift-test-load (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-09 22:55:24 211a6ee end swift-test-load rc=0 488s
    2026-11-09 22:55:24 211a6ee start tsan (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-09 23:45:59 211a6ee end tsan rc=0 3035s
    2026-11-09 23:45:59 211a6ee start tsan-load (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 00:45:49 211a6ee end tsan-load rc=0 3590s
    2026-11-10 00:45:49 211a6ee start ios-check (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 00:46:04 211a6ee end ios-check rc=0 15s
    2026-11-10 00:46:04 211a6ee start arc-check (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 00:46:09 211a6ee end arc-check rc=0 5s
    2026-11-10 00:46:09 211a6ee start golden (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 00:47:18 211a6ee end golden rc=0 69s
    2026-11-10 00:47:18 211a6ee start test-release (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 00:47:59 211a6ee end test-release rc=0 41s
    2026-11-10 00:47:59 211a6ee start model-check (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 00:48:19 211a6ee end model-check rc=0 20s
    2026-11-10 00:48:19 211a6ee start soak (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 00:49:33 211a6ee end soak rc=0 74s
    2026-11-10 00:49:33 211a6ee start fuzz-kasm (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 00:59:36 211a6ee end fuzz-kasm rc=0 603s
    2026-11-10 00:59:36 211a6ee start fuzz-snapshot (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 01:09:40 211a6ee end fuzz-snapshot rc=0 604s
    2026-11-10 01:09:40 211a6ee start fuzz-syntax (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 01:19:43 211a6ee end fuzz-syntax rc=0 603s
    2026-11-10 01:19:43 211a6ee start fuzz-protocol (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 01:29:46 211a6ee end fuzz-protocol rc=0 603s
    2026-11-10 01:29:46 211a6ee start apps (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 01:31:43 211a6ee end apps rc=0 117s
    2026-11-10 01:31:43 211a6ee start kernel-test (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 01:32:59 211a6ee end kernel-test rc=0 76s
    2026-11-10 01:32:59 211a6ee start new-check (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 01:37:02 211a6ee end new-check rc=0 243s
    2026-11-10 01:37:02 211a6ee start ab (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 01:42:21 211a6ee end ab rc=0 319s
    2026-11-10 01:42:21 211a6ee start matrix-mac (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 01:55:16 211a6ee end matrix-mac rc=0 775s
    2026-11-10 01:55:16 211a6ee start matrix-iphone (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
    2026-11-10 02:09:17 211a6ee end matrix-iphone rc=0 841s
    2026-11-10 02:09:17 211a6ee check-tier done core failed=0 12558s

A first run on aae5c35 (same day, `check-run1-aae5c35/`) failed two gates,
both in the new tools test: under twelve busy loops `definedInTag:` never
held, the browser's status reading "Error: no class Object". The cause was
an old race in the kernel, not this module's: `Smalltalk
rebuildClassNames` published an empty table and then filled it, so a
Process looking up a class while another rebuilt the table missed Object
(the define calls `forgetClassNames`, and the tools run several request
Processes at once). 211a6ee builds the table in a temporary and publishes
it whole, and `classNamed:` reads it once. Under ThreadSanitizer the same
test's harness ran out of its 30 s wait for `DevProtocol start`; it waits
120 s now with the assertion unchanged. The test passed 5 of 5 alone and
ToolsTests 2 of 2 under twelve busy loops before the second run.

### Deviations

- `class.categories` had no place in the brief; with categories gone it
  became `package.tags` (`DevSession>>packageTags:`, `DevClient
  packageTags:then:`).
- Primitive 148 also refuses a write whose own directory (below the
  opened root) is a symbolic link, even one leading inside: the brief's
  "a link in the tag's place is a refusal" taken literally. Before, such a
  write went through when the link stayed inside.
- The rewrite is two commits: 6148a24 put the seven files 923dc3c had
  edited by hand into the image's order at their old paths, so 43c948a is
  renames whose change is the key alone. Three five-line files show as
  delete and add at git's default 50 percent similarity.
- No class of `kernel/` is at the root: every kernel category had a tag,
  so `Object` is `kernel/Objects/Object.class.st`, not where the brief's
  example put it.
- `KernelBuild.sources(in:)` answers `(file, text, tag)`; a second
  `build` takes the old two-element files (the tests' generated ones, at a
  package's root).
- `class.define` of an existing class with neither `package` nor `tag`
  keeps its place, and with a tag alone uses the session's package; an
  empty tag is no tag.
- `ProjectWriter` removes a tag's directory when its last file goes.
- The end-to-end define ran in a test shell, not the Mac app's window.
- 211a6ee fixes a kernel race outside the brief (above).

### Not done

- Primitive 171: not needed, the move is the removal's mechanism.
- The fuzz seeds, the `Tests/KajoVMTests/Fixtures/smalltalk` bench kernels
  and the experiments' programs keep their `#category` keys (read and
  ignored).
- `kajo browse` with no class lists every class; it has no `--package`
  filter of its own (`kajo request class.list '{"package":...}'` has).
- No AGENTS.md or PLAN changes (the main session's).
- The iPad.

### Open questions for the owner (built as recommended)

1. The `category:` class-creation messages as a shorthand splitting
   `'Package-Tag'`? Built: no; `package:` and `package:tag:` only, and the
   browser refuses a `category:` definition naming the new form.
2. An extension file in a tag's subdirectory when its methods' category
   names one? Built: no; extension files stay at the package's root.
3. A class with no tag? Built: allowed, at the package's root (the
   fixtures `toolsprobe/`, `app-project/Sample/src/` and
   `apps/Shared/devsession` have only such classes; `kernel/` has none
   after the rule).
