# Review: smalltalk at 821f20f (the third review: mechanical sympathy, architecture, reuse)

Area: all Smalltalk source (`kernel/`, `tools/`, `types/`, `apps/Shared/smalltalk`).
Read only; nothing was built or run. Every number below is either quoted from a
doc of the repository (named) or counted by reading the code (said so). A send
is taken as the unit of cost: 58 cycles on fib in the aligned A/B of
`docs/modules/collections-speed.md`. Special sends that stay inline for
SmallIntegers (`+ - < <= = == at: at:put: size class value isNil`) are not
counted as sends; `bitAnd:`, `not`, `between:and:`, `max:`, `includes:` are.

## The findings, in the order I would do them

| id | one line | expected gain |
|---|---|---|
| smalltalk.M1 | `OrderedCollection>>grow` always doubles, so a FIFO's array grows with what passed through it, not with what it holds | memory of every long-lived queue bounded (the Transcript's 5000-line ring first) |
| smalltalk.M2 | `DevSession>>classSelectors:side:` builds the class's whole organization once per category; `handleOf:` scans every handle per described slot; `classHierarchy` sorts by two JsonObject searches per compare | a class selection's request about (categories + 1) times cheaper in the target; inspect no longer quadratic in the session |
| smalltalk.M3 | `includes:` on an Array or OrderedCollection is `Collection`'s: two closures and two block activations per element | 56 literal-array tests in product code become a loop with no allocation |
| smalltalk.M4 | `BytecodeGenerator` finds every fact about an opcode by scanning literal Symbol arrays, per instruction, in three passes | the Smalltalk compiler several times fewer sends per method; `CompilerTest`'s 23 s (691 s under the sanitizer) |
| smalltalk.M5 | Scanner and Parser: 5 to 7 sends per identifier byte, two sends per `self kind`, a saved and rescanned token per expression | compile, the type checker's first pass (1.7 s) and colouring share it |
| smalltalk.M6 | A dictionary lookup is 11 sends for a Symbol key and about 19 for a String: three hook sends per probe, a closure per `at:`, six sends in `String>>=` | 12 to 7 sends per Symbol lookup, 20 to 9 per String lookup, counted |
| smalltalk.M7 | Every read of a source, a category, a package, a definition or a class's types takes one global Mutex: two closures, a temp vector and `ensure:` per read | per method read 15 sends and 3 to 4 allocations less; workers stop queueing on one lock |
| smalltalk.M8 | JSON is read at 5 to 6 sends per byte and written at 2, and the tools read every reply on the UI Process | large replies leave the frame budget; strings read in a few sends each |
| smalltalk.M9 | Every keystroke re-reads the pane's text, parses the pattern, scans the whole text again and replaces every style | colouring independent of pane size, or bounded; the workspace first |
| smalltalk.M10 | The type checker parses the pattern of every method of every class it meets to learn whether it has types; names and dependency keys are Strings built by concatenation | 14 to 17 percent of the whole check (the doc's number) by a byte test; less garbage and a smaller index |
| smalltalk.M11 | `TonelWriter` builds a class file with `,`: the file so far is copied once per method, on every accept | linear text building; a compile in a large class stops rebuilding megabytes |
| smalltalk.M12 | `OrderedCollection>>at:` costs four sends; every inherited loop (`indexOf:`, `=`, `sort:`, `removeIndex:`) pays it per element | a sort or a search of an OrderedCollection near an Array's cost |
| smalltalk.M13 | Small per-call costs (a table) | each small; cheap to take together |
| smalltalk.A1 | Six parallel tables keyed by class hold what is known of a class; a seventh fact is a seventh table and a line in `forgetClass:` | one record per class; M7 becomes one lookup |
| smalltalk.A2 | The tools' models keep the protocol's JsonObjects as their own data | a reply's shape stops being the model's data structure; accesses stop being String searches |
| smalltalk.A3 | The type checker carries the experiment's eight switches and its counters in the product path | one mode in the product; the counters out of every send's check |
| smalltalk.A4 | The on-demand forms, `package.selectors` and the 4000-cell batches are used by a measurement only or left from the one-block limit | less code behind the view wrappers; or the long lists really on demand |
| smalltalk.R1 | The lexical rules of Smalltalk source are written in five places, the identifier rule in four | one scanner for tools and Tonel; one rule |
| smalltalk.R2 | `DevClient`'s 32 request methods and its table restate `DevSession`'s `<devProtocol>` methods by hand | one statement of a request |
| smalltalk.R3 | `BrowserModel` writes "is this reply still wanted" four ways and "one request outstanding" twice | one helper in `ToolModel` |
| smalltalk.R4 | A bounded wait is written in six tests and an unbounded yield loop in four | `TestCase>>waitUntil:`; no test spins a worker |
| smalltalk.R5 | Eight class-side registries each write their lock, lazy start and `at:ifAbsent:` under it | one locked table; one place to make reads cheap (M7) |

Counts: 13 mechanical, 4 architecture, 5 reuse.

## Mechanical

### smalltalk.M1. A FIFO's backing array grows with its throughput

- **Where**: `kernel/Collections/OrderedCollection.class.st:33-44` (`addFirst:`, `addLast:`), `:93-102` (`grow`), `:121-128` (`removeFirst`). Users: `tools/Models/TranscriptModel.class.st:23-30`, `kernel/Processes/SharedQueue.class.st:17-32`, `kernel/Processes/Monitor.class.st:24-43`, `kernel/Development/DebugStop.class.st:90,110,246`.
- **What is there now**: `addLast:` grows when `lastIndex = array size`, and `grow` is `bigger := Array new: (array size * 2 max: 8)` with the elements centred, whatever the collection holds. `removeFirst` only advances `firstIndex`. Nothing moves the elements back or resets the indices when the collection empties.
- **The cost**: with `addLast:` and `removeFirst` in turn, the tail reaches the end of the array again after about half the array's size of adds, and the array doubles. After N adds the array has about N slots though the collection holds a constant few. `TranscriptModel` keeps 5000 lines and adds forever (`lines add: line. lines size > 5000 ifTrue: [lines removeFirst: 1000]`): a million transcript lines leave a million-slot Array (8 MB, a large object, old at birth), and each growth copies and drops the previous large object. The same holds for any app that uses an OrderedCollection as a queue, which is the idiom.
- **The proposal**: in `grow`, with `n := self size`: when `n * 2 <= array size`, slide the elements to the centre of the same array (`replaceFrom:to:with:startingAt:`, primitive 38; clear the vacated slots) and do not allocate; else double as now. In `removeFirst` and `removeLast`, when the collection becomes empty, reset `firstIndex` and `lastIndex` to the centre.
- **Bound before, measure after**: a kernel test that adds and removes 100 000 times with at most 10 held and asserts on `array size` through `slotAt:` (it fails today: about 131 072). After: the collections-speed parts (`collections-oc` must not move; it only appends), `kajo run`'s old-space bytes for a queue loop.
- **Risk and size**: `OrderedCollectionTest`, `ProcessTest` (SharedQueue). An overlapping copy within one array: primitive 38 "runs the loop" when the target overlaps after its source, so the slide may fall back to the Smalltalk loop; correct either way. Smalltalk tier. Small.
- **Confidence**: read.

### smalltalk.M2. Three request handlers repeat work per element

- **Where**: `kernel/Development/DevSession.class.st:181-190` (`classSelectors:side:`), `:64-72` (`handleOf:`), `:160-168` (`classHierarchy`), `:171-178` (`classList:tag:`); `kernel/Classes/Behavior.class.st:354-361` (`organization`).
- **What is there now**:
  ```
  (b organization keys asArray sort: [:x :y | x <= y]) do: [:cat |
      o at: cat put: ((b organization at: cat) collect: [:s | s asString]) asArray].
  ```
  `organization` is not an accessor: it makes an IdentityDictionary from every selector, asking `Smalltalk categoryOfSelector:in:` (the registry lock, M7) per selector, and sorts each category. `handleOf:` finds an object's handle with `handles keysAndValuesDo:` over every handle of the session. `classHierarchy` builds a JsonObject per class and then sorts them by `(a at: 'name') <= (b at: 'name')`.
- **The cost**: `class.selectors` is the request of every class selection and every accept in the browser (`BrowserModel>>loadSelectors`). For a class with c categories and s selectors it builds the organization c + 1 times: Object (13 categories, 82 methods, counted in its file) is 14 builds, each 82 locked reads and 13 sorts; `Smalltalk class` (12 categories, 89 methods) 13 builds. `inspect` describes up to 100 indexed slots and every named one, and each `describe:` scans every handle the session holds; handles are only released when the client says so, so the scan grows with the session and an inspect is (slots x handles). `classHierarchy`'s sort does two linear String-key searches of a JsonObject per comparison, about 22 000 comparisons for 2000 classes.
- **The proposal**: `org := b organization` once in `classSelectors:side:`; `selectorsInCategory:` the same shape (`Behavior.class.st:364-367` builds the whole organization for one category). A second table in the session, `IdentityDictionary` object to handle, kept with `handles` under the same lock. `classHierarchy`: sort the classes by `name` first, then build the objects in order; `classList:tag:` asks `tagOf:` once.
- **Bound before, measure after**: `kajo run`'s `sends` for a program that calls `DevSession new classSelectors: 'Object' side: nil` 100 times, before and after; the scripted session's `class.hierarchy` round trip and its `select 10` step (`mode=devsession classes=2000`, five a side interleaved, as collections-speed did); a test that inspects an Array of 100 elements 50 times and reads the sends of the last against the first.
- **Risk and size**: the handle map must be emptied where `handles` is (`inspect.release`, the session's end: `DevSession.class.st:403`), or it roots the objects; `DevelopmentTest` covers handles. Smalltalk tier. Small.
- **Confidence**: read.

### smalltalk.M3. `includes:` on a sequence allocates two closures and runs two blocks per element

- **Where**: `kernel/Collections/Collection.class.st:226-228` (`includes:`), `:211-213` (`identityIncludes:`), `:89-92` (`anySatisfy:`); no override in `SequenceableCollection`, `Array` or `OrderedCollection` (only `Set` and `Dictionary` override). 56 lines of product code send `#(...) includes:` to a literal Array (counted with `grep`), among them `Compiler.class.st:80,83,118,122,195,213-219`, `BytecodeGenerator.class.st:54,133,138,146,199-221,244-257`, `Parser.class.st:212,611`, `Json.class.st:62,148`, `SourceColorer.class.st:28`, `TonelReader.class.st:122,167,225,228`, `TonelWriter.class.st:53,112`.
- **What is there now**: `includes: anObject ^ self anySatisfy: [:e | e = anObject]`, and `anySatisfy:` is `self do: [:e | (aBlock value: e) ifTrue: [^ true]]`. Per call: two closures made (one with a home for the non-local return), then per element the `do:` block, the `anySatisfy:` block and `=`.
- **The cost**: per element two block activations and a send where one compare would do, and two allocations per call where none is needed. A Symbol in a six-element literal is about 20 sends and 2 objects to learn "no". `Json>>skip` pays it per blank test, `Compiler>>inlinable:` four times per message node.
- **The proposal**: in `SequenceableCollection`:
  ```
  includes: anObject
      1 to: self size do: [:i | (self at: i) = anObject ifTrue: [^ true]].
      ^ false
  ```
  and `identityIncludes:` with `==`. `OrderedCollection` gets the same over `array` from `firstIndex` to `lastIndex` (its `at:` is M12). `String` keeps `Collection`'s (its `at:` is refused) or gets `indexOfSubstring:`.
- **Bound before, measure after**: `sends` of a loop of a million `#(#a #b #c #d #e #f) includes: #z`, before and after; then `CompilerTest>>testEveryMethodCompilesAsTheBootstrapDid`'s time (23.3 s in `docs/modules/gate-speed.md:389`), which is the largest user.
- **Risk and size**: none beyond `ArrayTest`, `OrderedCollectionTest`; an `Interval` inherits it and works through `at:`. Smalltalk tier. Small.
- **Confidence**: read.

### smalltalk.M4. The assembler looks every opcode fact up by scanning literal arrays

- **Where**: `kernel/Compiler/BytecodeGenerator.class.st:14-73` (`assembleWithExtraLiterals:`), `:101-124` (`maxStackOf:`), `:132-260` (the class side: `endsBlock:`, `isExtensible:`, `length:`, `number:`, `operands:`, `pops:argc:`, `pushes:`, `special:arguments:`, `specialArgc:`, `transientDepth:`); `kernel/Compiler/Compiler.class.st:345-367` (`emit:`), `:652-655` (`label`), `:208-224` (`inlinable:`), `:168-177` (`chainOf:`).
- **What is there now**: the generator emits a 4-element Array per instruction with the opcode as a Symbol (`e add: {#op. op. a. b}`); the assembler copies each into a second 4-element Array, then walks the instructions three times. Each walk asks the class side, and every answer is a chain of `#(...) includes: op`:
  ```
  operands: op
      (#(#pushTemp #pushLiteral #pushIvar #storeTemp #storeIvar #pushNewArray) includes: op) ifTrue: [^ #index].
      op == #pushInt ifTrue: [^ #int8].
      (#(#send #sendSuper) includes: op) ifTrue: [^ #send]. ...
  number: op  ^ (self opcodes indexOf: op) - 1
  ```
  Labels are Strings (`'L' , labelCounter printString`) and keys of a `Dictionary`. `Compiler>>inlinable:` runs four `includes:` over 13 selectors for every message node, and `chainOf:` asks it again for every receiver of a chain.
- **The cost**: per instruction, by reading: `isExtensible:` twice (11 elements each), `length:` (through `operands:`, up to 13 elements, then 3), `number:` (a scan of up to 50 Symbols with a send of `=` each), `operands:` again, `pops:argc:` (up to 26 elements), `pushes:` (12), `transientDepth:`, `endsBlock:`, two `max:`. With M3's cost per element that is 300 to 400 sends and about 14 closures per instruction, for an instruction of one to three bytes, plus two Arrays; a label is a `printString`, a concatenation, and a String hash and compare at its definition and at each jump (twice: assembly and the depth trace). The measured whole: `CompilerTest>>testEveryMethodCompilesAsTheBootstrapDid` takes 23.3 s plain and 691 s under ThreadSanitizer (`docs/modules/gate-speed.md:389`), the slowest kernel test, in every tier's kernel-test gate and both sanitizer gates. The same compiler runs for every method of a Tonel file loaded into a running image (`TonelLoader`) and for every method of a redefined class and its subclasses.
- **The proposal**: one table made once (a class-side instance variable filled by `BytecodeGenerator class>>initialize`, which the image build runs): `IdentityDictionary` from the opcode Symbol to a descriptor Array `{number. operand kind. length. pops (or the rule's tag). pushes. transient. ends block. extensible}`. `emit:` looks the descriptor up once and stores it in the line, so the three passes read slots. Labels are SmallIntegers and `labels` an Array indexed by them. `inlinable:` asks an `IdentitySet` of `Compiler class>>inlinedSelectors` (the list exists, `Compiler.class.st:704-706`) before the chain of tests, and marks the node so `chainOf:` does not ask again (`chainOfAnalysed:` already reads such a mark).
- **Bound before, measure after**: the cheating build first: memoize `number:`, `operands:`, `pops:argc:`, `pushes:` and `isExtensible:` in one IdentityDictionary each, change nothing else, and read `CompilerTest`'s time and `kajo test --test`'s `sends`. If that does not move it by a third, the time is elsewhere (M5, the comparison's own `sameCodeAs:`), and the table is not worth its code. After: the same test, plain and under the sanitizer, against `gates.log` of the previous module.
- **Risk and size**: the two compilers must agree byte for byte: `CompilerTest`, the corpus (`Tests/KajoCompilerTests/Fixtures/compiler-corpus/corpus.txt`), `scripts/fuzz.sh syntax-kernel`. The table is a second statement of `Opcodes.swift`, as the scans are now; a kernel test that compares it with what primitive 166 and the VM's verifier accept would be new. Smalltalk tier, with the syntax fuzzer's kernel mode run by hand. Medium.
- **Confidence**: read for the code; the share of the 23 s is inferred.

### smalltalk.M5. The Scanner and the Parser spend sends per byte and per token

- **Where**: `kernel/Compiler/Scanner.class.st:63-80` (`isIdentifierPartAt:`, `isLetterAt:`), `:44-50` (`identifierRun`), `:53-55` (`isBinaryByte:`), `:24-31` (`digits:`), `:258-276` (`skipSpace`); `kernel/Compiler/Parser.class.st:47-49` (`kind`), `:410-412` (`value`), `:14-17` (`advance`), `:142-158` (`parseExpression`), `:604-615` (`typeFollowsAfter:`); `kernel/Text/Character.class.st:83-91`.
- **What is there now**:
  ```
  isIdentifierPartAt: i
      ...b := source byteAt: i.
      b < 128 ifTrue: [^ (b between: 65 and: 90) or: [(b between: 97 and: 122) or: [b = 95 or: [b between: 48 and: 57]]]].
  isBinaryByte: b
      ^ b > 0 and: [b < 128 and: ['+-*/\<>=~&|@%,?!' includes: (Character value: b)]]
  Parser >> kind  ^ scanner kind
  parseExpression
      self kind == #identifier ifTrue: [
          save := {scanner state. lastEnd}. ... self advance.
          self kind == #assign ifTrue: [...].
          scanner restore: save first. lastEnd := save last].
  ```
- **The cost**: an identifier byte costs `isIdentifierPartAt:`, `byteAt:`, one to four `between:and:` (a real send to `Magnitude`) and `scalarSizeAt:`: 5 to 7 sends. `isBinaryByte:` is a `Character value:` and a generic `includes:` over a 16-character String (M3: about 50 sends and two closures), called two or three times per binary operator. The parser asks `self kind` 15 to 20 times per expression (`parseStatementsInBlock:`, `atStatementsEnd:`, `parseExpression`, `parseUnaryMessages:`, `parseBinaryMessages:`, `parseMessages:`, `parseCascade:`), two sends each, though `Scanner>>next` already answers the kind. Every expression that starts with an identifier makes a 7-element and a 2-element Array, scans the next token, restores, and scans that token again when the primary is consumed; a keyword or a string there is allocated twice. The users: the compiler (M4's 23 s), the type checker, which parses every method it checks and the pattern of every method of every class it reads (1.7 s for the first request, 0.54 ms a method, `docs/modules/types-2.md:641-645`, `docs/modules/types-3.md:36`), the Tonel reader and writer (a pattern parse per method), and the colourer per keystroke (M9).
- **The proposal**: (1) ASCII tests as compares on a temp (`b >= 97 and: [b <= 122]`) and `position + 1` for a byte below 128; (2) a 128-byte literal ByteArray for the binary characters, `(BinaryBytes at: b + 1) = 1`; (3) `Parser` keeps `kind` and `value` in instance variables set in `advance` (`kind := scanner next`); (4) `parseExpression` reads the identifier as a primary and, when `:=` follows and the primary is that bare variable, makes the assignment, so nothing is saved or restored (the check for `nil := 3` stays where the analysis has it); (5) `Character>>isDigit` and `isLetter` with one `value` and compares.
- **Bound before, measure after**: a kernel program that runs `Parser parse:` over every method source of the image and prints sends and time; it is the part of M4's 23 s and of the checker's 1.7 s that is parsing, and no doc has that number. After: the same program; the first `diagnostics` request headless (types-3's measure); the typing rows.
- **Risk and size**: "token for token" with the bootstrap scanner is the invariant; the corpus (186 entries) and the syntax fuzzer's kernel mode guard it, and `TypeSyntaxTest`. Item 4 changes which token is current at an error, so the error line of a malformed assignment must be compared on the corpus. Smalltalk tier plus `syntax-kernel`. Medium.
- **Confidence**: read; the share of each consumer's time is inferred.

### smalltalk.M6. A hashed lookup pays three hook sends per probe, a closure per `at:`, and six sends for a String compare

- **Where**: `kernel/Collections/HashedCollection.class.st:35-43` (`indexFor:`), `:20-22,30-32,46-48` (the hooks); `kernel/Collections/Dictionary.class.st:48-50` (`at:`), `:53-59`, `:62-64` (`at:ifAbsentPut:`), `:132-134`; `kernel/Collections/IdentityDictionary.class.st:8-14`; `kernel/Text/String.class.st:51-54` (`=`); `kernel/Numbers/SmallInteger.class.st:136-142`; `kernel/Collections/SequenceableCollection.class.st:94-99` (`hash`).
- **What is there now**:
  ```
  indexFor: key
      i := ((self hashFor: key) bitAnd: n - 1) + 1.
      [(e := array at: i) == nil or: [self equal: (self keyOf: e) to: key]] whileFalse: [...]
  Dictionary >> at: key
      ^ self at: key ifAbsent: [KeyNotFound new key: key; signal: 'key not found: ' , key printString]
  String >> = anObject
      ^ (anObject isString and: [anObject isSymbol not and: [self isSymbol not]]) and: [self sameBytesAs: anObject]
  ```
- **The cost**: a found Symbol key at the first probe, counted: `at:`, `at:ifAbsent:`, `indexFor:`, `hashFor:`, `hash`, `bitAnd:`, `keyOf:`, `key`, `equal:to:`, `=`, `value`: 11 sends and one closure made. The module measured 12.1 sends (339 ns) for a Symbol and 19.8 (464 ns) for a String (`docs/modules/collections-speed.md`, part 4), and listed "the probe's hooks unchanged" and "`at:` its block" under Not done; the owner's decision was against a probe primitive, not against this. `String>>=` is `isString`, `isSymbol`, `not`, `isSymbol`, `not`, `sameBytesAs:`: six sends where the class test is inline. `at:ifAbsentPut:` probes twice on a miss. Users with String keys on hot paths: `TypeScope` (two dictionaries probed per scope level per variable read), the checker's results and index, `BytecodeGenerator`'s labels, `View`'s headless properties.
- **The proposal**: keep one probe method per class, with the hooks written in: `Dictionary>>indexFor:` (`key hash`, `e key = key`), `Set>>indexFor:` (`key hash`, `e = key`), `IdentityDictionary>>indexFor:` (`key identityHash`, `e key == key`), `IdentitySet>>indexFor:`; four methods of eight lines, the hooks left for `rehashTo:` or written in there too. `Dictionary>>at:` probes itself and sends `self keyNotFound: key` on a miss. `at:ifAbsentPut:` stores at the index the miss found, probing again only when the block changed `tally` or `array` (a block may add keys or grow the table). `String>>=` is `^ self class == anObject class and: [self sameBytesAs: anObject]` (`Symbol` overrides `=`, so the receiver is a String; a Symbol argument fails the class test), the shape `ByteArray>>=` already has. Counted after: Symbol key in a Dictionary 7 sends, in an IdentityDictionary 6, a String key 8 or 9.
- **Hash quality, a measurement only**: `SmallInteger>>hash` is `self` and the index is `hash bitAnd: n - 1` with linear probing, so integer keys that are multiples of the capacity (ids in steps of 1024, byte offsets of aligned records) all start at one slot and a table of them is one cluster. `SequenceableCollection>>hash` reads the size and the first four elements, so Arrays that differ later collide. No table in the product has such keys that I found; the counter to add first is probes per lookup in a checked build, before any change of a hash (which would change iteration order, and the Tonel round trip is byte-identical by test).
- **Bound before, measure after**: collections-speed's own programs: the lookup loops that gave 12.1 and 19.8 sends, and the `collections-dict` part (1.69 s, net 1.49 of Pharo). After: the same, the whole program against 4.45 s, and the first `diagnostics` request.
- **Risk and size**: iteration order does not change (same hash, same probe). `DictionaryTest`, `SetTest`, `RegistryTest`, the canonical Tonel check. A subclass that overrides only a hook would no longer be asked by the probe: there is none in the three packages (`grep 'hashFor:\|equal: .* to:'` finds only the Identity classes), and the hooks should then go. Smalltalk tier. Small to medium.
- **Confidence**: read; the send counts are counted, not run.

### smalltalk.M7. Every registry read takes one global Mutex

- **Where**: `kernel/System/Smalltalk.class.st:718-722` (`registry:`), `:742-745` (`sourceOf:`), `:524-527` (`definitionOf:`), `:748-751` (`typesOf:`), `:518-521` (`categoryOfSelector:in:`), `:373-379` (`packageOfSelector:in:`), `:367-370`, `:382-385`, `:577-588` (`instanceVariableNamesOf:`); `kernel/Processes/Mutex.class.st:12-19`. Callers per element: `Behavior>>organization` (per selector), `DevSession>>classHierarchy` (`packageOf:` and `tagOf:` per class: two), `DevSession>>packageSelectors:` (per method: `packageOfSelector:in:` and then `packageOf:`: two), `TonelWriter>>methodsOf:package:` and `method:in:category:` (two per method), `TypeTable>>build:` (`sourceOf:` per method), `MethodTypeCheck>>run` (`sourceCode`, `instanceVariableNamesOf:`: one lock per class of the chain, per method checked), `Compiler>>setClass:`.
- **What is there now**:
  ```
  sourceOf: aCompiledMethod
      ^ self registry: [sources isNil ifFalse: [(sources at: aCompiledMethod methodClass ifAbsent: [nil]) ifNotNil: [:d | d at: aCompiledMethod ifAbsent: [nil]]]]
  Mutex >> critical: aBlock
      me := ProcessorScheduler activeProcess. owner == me ifTrue: [^ aBlock value]. caught := false.
      ^ [semaphore wait. caught := true. owner := me. aBlock value] ensure: [caught ifTrue: [owner := nil. semaphore signal]]
  ```
- **The cost**: per read, beside the two IdentityDictionary lookups (M6): the reader's block (a closure), `registry:`, `critical:`, `activeProcess`, a temp vector for `caught` and `owner`'s neighbours, the protected closure, the ensure closure, `ensure:`, `value`, `wait`, the block, the ensure block, `signal`: about 15 sends and 4 allocations. It is one lock for the image: the type checker's background Process, a protocol request on another worker and a compile all meet on it, and a waiter on a Smalltalk Semaphore is a Process switch. Requests "run in Processes of their own, in parallel" (the lock's own comment) and then take turns here.
- **The proposal**, in two steps. (1) Readers that loop take what they need once per class: `Smalltalk sourcesOf: aBehavior`, `categoriesOf:`, `packagesOf:` answer the per-class dictionary (a copy, or the published one after step 2) under one acquisition, and `organization`, `classHierarchy`, `packageSelectors:`, `methodsOf:package:` and `TypeTable>>build:` read from it; `instanceVariableNamesOf:` is cached per class in the checker (`TypedClass`) and in `Compiler>>setClass:` it is already once per compile. (2) Reads without the lock: writers keep the Mutex and publish; a per-class dictionary is replaced by a changed copy, never written in place (writes are compiles and class changes, rare), and `rehashTo:` already publishes a filled table (`HashedCollection.class.st:56-67`). A reader then loads `sources`, probes, loads the class's dictionary, probes.
- **Bound before, measure after**: step 1's bound is a count: `Mutex>>critical:` entries per `class.hierarchy`, per `class.selectors` and per method checked (a counter in a scratch build, or sends of the handler alone). Step 2's cheating build: `registry:` answering `aBlock value` in an image that only reads (the type checker's whole pass, `checkAll`): the difference is the ceiling. After: the first `diagnostics` request, the scripted session's two round trips, and `RegistryTest` under load.
- **Risk and size**: step 2 changes what the second review's F4 fixed. The invariant is "a reader never sees a table being filled or emptied in place": `removeAt:` re-places a cluster in place (`HashedCollection.class.st:75-86`), so removal must also be copy and publish; `RegistryTest` (the registries' lock under load) must get a reader that runs during writes and checks that a present key is never missed. No model covers it. Smalltalk tier, run under load as the interning tests are. Step 1 small; step 2 medium.
- **Confidence**: read for the costs; the contention between workers is inferred (no row measures it).

### smalltalk.M8. JSON costs sends per byte, and the tools pay them on the UI Process

- **Where**: `kernel/Development/Json.class.st:17-19` (`byte`), `:147-149` (`skip`), `:102-123` (`readString`), `:54-67` (`number`), `:163-165` (`bytes:on:`), `:177-212` (`write:on:depth:`), `:224-241` (`writeString:on:`); `kernel/Development/JsonObject.class.st:17-33`; `kernel/Development/JsonPieceStream.class.st:20-27`; `tools/Client/DevClient.class.st:275-285` (`receiveLine:`).
- **What is there now**: the reader's `byte` is `position <= source byteSize ifTrue: [source byteAt: position] ifFalse: [0]` (three sends), `skip` is `[#(32 9 10 13) includes: self byte] whileTrue:` (M3), `readString` takes a byte at a time through `self byte`, a bound test and `out nextPut:`. The writer walks every string a byte at a time (`byteAt:`, six compares, `nextPut:`) and finds an object's kind by `isInteger`, `isFloat`, `isString`, `isCharacter`, then `isKindOf: JsonObject`, `isKindOf: Dictionary`, `isKindOf: Array` (each a walk up the superclass chain). A JsonObject is written through `anObject keys` (a copy) and `anObject at: k` (a linear search per key). `DevClient>>receiveLine:` calls `Json read:` in the handler of the `#line` event, on the event loop's Process.
- **The cost**: reading is 5 to 6 sends per byte of a string and about 12 per blank test; writing is 2 sends per byte and about 25 of dispatch per Array or JsonObject. A reply is written once in the target and read once in the tools: `class.hierarchy` of 2000 classes is on the order of 150 KB, a class's Tonel text after every accept is the class file (12 to 34 KB for Object, String, Behavior and Smalltalk). The read runs on the main-affine event loop, whose turns are budgeted per frame, so its CPU time becomes several frames of latency rather than one stretch; the round trips the docs report (`class.hierarchy` 234 ms, `docs/modules/collections-speed.md` part 5) are consistent with that, but no row splits a round trip into the target's time, the read and the model's work.
- **The proposal**: (1) Reader, for a String source: `readString` finds the closing quote with primitive 134 (`indexOfSubstring: '"' startingAt:`) and takes the run with `copyFrom:to:` when no backslash lies before it; the next backslash's offset is found the same way and remembered, so the whole text is scanned twice at most. `byte` is inlined where it is hot and `skip` compares. (2) Writer: `jsonOn: aStream depth:` in Object, String, Symbol, Integer, Float, Array, OrderedCollection, Dictionary, JsonObject, UndefinedObject, Boolean (one send instead of the chain; the classes are the kernel's own); a JsonObject written with `keysAndValuesDo:`; a string's clean runs copied with primitive 38 into the piece (the scan for a byte to escape stays one `byteAt:` per byte unless a primitive is added; state the bytes written per session before asking for one). (3) The client parses on a background Process: the `#line` handler hands the text to a parser Process and the parsed object comes back to the event loop as an event of its own (`UIEventLoop on:do:` has the seam), so the UI Process only runs the model's block.
- **Bound before, measure after**: the scripted session with three timestamps per reply in `DevClient` (line arrived, parsed, block returned) beside the target's own serve time (`requests-<tag>.txt` exists for that); that table says which of the three steps is worth building. After: the same table; frames missed in the session.
- **Risk and size**: the reader is a trust boundary on the target's side (requests) and reads replies on the client's: `fuzz-protocol` and the kernel's `DevelopmentTest` for (1); (2) must write the same bytes (`Sources/KajoDev/JSON.swift` "writes them alike"): a test that compares old and new writers on the session's replies. (3) changes ordering assumptions: replies must reach the model in arrival order (one parser Process, a queue), and `DevClientTest`'s fake fires synchronously. Smalltalk tier; the protocol fuzzer because the reader changes. Medium.
- **Confidence**: read for the per-byte costs; the reply sizes and the latency share are inferred.

### smalltalk.M9. Colouring is a whole-pane job per keystroke

- **Where**: `tools/Windows/BrowserWindow.class.st:106` (`onChange: [:v | self edited. self colour]`), `:121-132` (`colour`); `tools/Windows/WorkspaceWindow.class.st:21`; `tools/Client/SourceColorer.class.st:40-63`, `:23-31`, `:8-20`; `kernel/UI/TextView.class.st:37-39`, `:100-103`.
- **What is there now**: on every `textChanged` event the window reads the pane's whole text through a view call, `SourceColorer` runs `Parser new setSource:; parsePattern` for the pattern's end and the type spans, then a second `Scanner` over the whole text, walks the bytes between tokens again for comments (`commentsIn:from:to:into:`, a `byteAt:` per byte the Scanner already skipped), tests each identifier with `#('self' 'super' 'thisContext' 'true' 'false' 'nil') includes: aValue` (six String compares through M3), and replaces every style with one `setStyles` call. The Scanner builds each token's value (a String per identifier, the digits of a number, a string's contents) though colouring needs the kind, the range and the first byte. The workspace colours its whole text the same way.
- **The cost**: linear in the pane, on the main thread, per key. Measured for one method of the development image: 0.7 ms at p50 with the storm running and 2.7 ms on an idle machine, where the main thread's clock is slow (`docs/modules/developer-ui.md:361-368`); a view call is about 0.02 ms (ADR 0010). The turn's budget is 3 ms, so a text ten times that method (a long method, any workspace that has been used for an hour, since print-it appends to it) is past a frame on the Mac and sooner on a phone.
- **The proposal**: (1) a colouring pass in `Scanner` that answers kind, start and stop without building values and reports comments as it skips them, so one pass replaces three (the pattern's end is where the first non-pattern token starts: read the pattern with the same scanner state rather than a second Parser); (2) the six pseudo-variable names tested by first byte and length before any compare; (3) one colouring per turn: the handler marks the pane dirty and the colouring runs once when the queue is empty (a paste or a key repeat is several events); (4) above a size, colour only the lines around the edit and keep the other styles (needs a `setStyles` over a range in the hosts; or do not colour a workspace past N bytes and say so in the status line).
- **Bound before, measure after**: the existing typing measurement (`mode=devsession typing=200`) at three source sizes (1, 10, 50 KB) on the base: "key to colours" against size is the bar for whether (4) is needed. After: the same three rows, idle and under the storm.
- **Risk and size**: the colourer shares the kernel's Scanner so that colours follow the language; (1) keeps that. `SourceColorerTest`, the typing rows. (4) is a host change (Swift tier). Parts 1 to 3: Smalltalk tier, small to medium.
- **Confidence**: read; the scaling with size is inferred from the code and the one measured size.

### smalltalk.M10. The type checker: patterns parsed to find out there is nothing, and Strings as keys

- **Where**: `types/Checker/TypeTable.class.st:112-149` (`build:`), `:225-227` (`keyOf:in:`), `:256-266` (`signaturesFor:from:`); `types/Checker/TypeChecker.class.st:255-257`, `:279-304`; `types/Checker/MethodTypeCheck.class.st:327-359` (`run`, `:346` `ivarNames`), `:534`, `:546`, `:579`, `:717`; `types/Checker/TypeScope.class.st:103-108`; `types/Live/TypeService.class.st:108-111`.
- **What is there now**: `build:` reads a class by parsing the pattern of every method of both sides (`(Parser new setSource: src) parsePattern`) and keeps those with a type (`hasTypes:`). A lookup walks the superclass chain and builds each class on the way, so checking one class builds Object, Behavior and every class its sends reach. Every key is a String made by concatenation: `aBehavior name , '>>' , aSelector` per method checked and per inferred callee, `'sel:' , aSymbol` and `'body:' , key` per unannotated send. Variables are looked up by name in `TypeScope`'s `vars` and `narrowed`, two String-keyed Dictionaries per scope, and a scope makes three Dictionaries when it is made. `run` computes `(Smalltalk instanceVariableNamesOf: base) collect: [:s | s asString]` for every method of the class. The index is scanned whole with `endsWith:` and `beginsWith:` (byte loops in Smalltalk) at each signature or class change.
- **The cost**: the docs give the first: "reading every pattern through the Parser is the difference", 14 to 17 percent of 1.7 s (`docs/modules/types-2.md:641-645`); 27 class files carry the typed signatures and about 150 carry none, yet all are parsed. The index holds 3201 keys and 14 718 edges as Strings: 1.08 MB (`types-2.md:660`). A variable read at block depth 3 is six String-keyed probes (M6: about 19 sends each before that finding). Per method: a registry lock per class of the chain (M7) and an `asString` (`'' , self`) per instance variable.
- **The proposal**: (1) before parsing a pattern, `(src indexOfSubstring: '<' startingAt: 1) = 0 ifTrue: [skip]` (primitive 134, one send): a method with no `<` anywhere has no type; the rest are parsed as now. (2) Names as Symbols at the boundary (the Parser's identifier values interned once per token, or `asSymbol` where a name enters a scope) and `IdentityDictionary` in `TypeScope`; `narrowed` and `kinds` made when first written. (3) Dependency keys as objects compared by identity: a per-checker table from (kind, behavior, selector) to one key object, the index an IdentityDictionary, and the two scans replaced by a second table from selector and from class to its keys. (4) `ivarNames` kept in the `TypedClass`.
- **Bound before, measure after**: the module's own measure (`~/kajo-scratch/types-2/` `measure.txt`: whole image, a body change, ten signature changes) with a counter of patterns parsed and patterns kept: (1)'s gain is parsed minus kept, known before it is built. After: the same rows and the footprint walk (`measure/new-footprint`).
- **Risk and size**: (1) is exact for the grammar as it is (a type is written with `<`); a comment or a string holding `<` only costs a parse. The diagnostics must not change: `TypeCheckerTest`, the 81 diagnostics by class of types-3, the broken variants in `~/kajo-scratch/types-2/scripts/broken.sh`. Smalltalk tier (the checker is not in a release image; `new-check`'s `checker_classes` row unaffected). (1) small; (2) to (4) medium.
- **Confidence**: read; the 14 to 17 percent is the doc's, the rest inferred.

### smalltalk.M11. The Tonel writer builds text by concatenation

- **Where**: `kernel/System/TonelWriter.class.st:245-253` (`sourceOf:package:`), `:129-139` (`method:in:category:`), `:171-184` (`patternAndBodyOf:`), `:75-101` (`headerOf:`), `:119-126` (`list:of:`), `:265-273` (`typeOf:`); `kernel/Text/String.class.st:493-505,540-547` (`String lf`, `tab`, `with:`); the caller on every change: `kernel/Development/DevSession.class.st:100-111` (`filesFor:`).
- **What is there now**: `(self methodsOf: aClass package: aName) do: [:m | out := out , m]`, each method's text itself a chain of about 14 `,`; `patternAndBodyOf:` parses each method's pattern again (`Scanner patternEndIn:`) to put the bracket after it; `typeOf:` makes an eight-entry Dictionary per call; `String lf` and `String tab` each make a WriteStream, a 32-byte buffer and a String per call (17 call sites in product code, several inside loops).
- **The cost**: every `,` copies both sides, so the file so far is copied once per method: `Smalltalk.class.st` (34 KB, 89 methods) is about 1.5 MB copied and 89 dead Strings of growing size, per write. A write happens on every accept of a method, a comment or a definition through a session (`changed:` answers the class's whole file), and for every class of `writeTonel:`.
- **The proposal**: one `WriteStream on: String new` passed down (`headerOf:on:`, `method:in:category:on:`): `nextPutAll:` of a String is one primitive copy and the buffer doubles. `String lf`, `tab`, `space`, `cr` answer a literal or a class-side constant made once. `typeOf:` reads a literal Array of pairs. Keep `patternAndBodyOf:`'s parse (the canonical form depends on it), or record the pattern's end with the source when a method is compiled, which the compile already knows (`Parser>>lastEnd`).
- **Bound before, measure after**: `sends` and allocated bytes of `TonelWriter sourceOf: Smalltalk class` and of `Smalltalk writeTonel:` on the kernel, before and after; the `method.compile` round trip for a method of Object in the scripted session.
- **Risk and size**: the output must not change by a byte: `scripts/canonical-tonel.sh --check` and `TonelTest` are the oracle, as they were for collections-speed's WriteStream change. Smalltalk tier. Small.
- **Confidence**: read.

### smalltalk.M12. `OrderedCollection>>at:` is four sends, and the inherited loops use it

- **Where**: `kernel/Collections/OrderedCollection.class.st:55-64` (`at:`, `at:put:`), `:110-113` (`remove:ifAbsent:`), `:136-143` (`removeIndex:`), `:26-30` (`add:beforeIndex:`), `:75-80` (`copyFrom:to:`); inherited from `kernel/Collections/SequenceableCollection.class.st`: `indexOf:ifAbsent:` (`:48-51`), `=` (`:85-91`), `doWithIndex:`, `keysAndValuesDo:`, `with:do:`, `insertionSortFrom:to:by:` (`:192-200`), `sort:` (`:224-240`).
- **What is there now**: `(index isInteger and: [index between: 1 and: self size]) ifFalse: [^ self indexError: index]. ^ array at: firstIndex + index - 1`: `at:`, `isInteger`, `between:and:`, `size`. `sort:` on an OrderedCollection runs the insertion sort of each run of 8 through `self at:` and `self at:put:` and copies in and out element by element. `removeIndex:` shifts with a loop of `self at: i put: (self at: i + 1)`.
- **The cost**: four sends per access where an Array's `at:` is none. The collections-speed sort row (3.03 sends per element) was an Array; the same sort of an OrderedCollection is roughly 2 accesses per comparison of the insertion pass and 2 per element of the copies, each four sends. `remove:` of an early element is eight sends per element shifted. The tools' models keep lists in OrderedCollections and index them.
- **The proposal**: `at:` as `| i | i := firstIndex + index - 1. (index >= 1 and: [i <= lastIndex]) ifFalse: [^ self indexError: index]. ^ array at: i` (a non-integer index fails in the compare or in the Array's own `at:` and reaches `indexError:` through a fallback); `sort:` in OrderedCollection sorts `array` between the two indices (the merge and insertion methods take `lo` and `hi` already); `removeIndex:` and `add:beforeIndex:` move the tail with `replaceFrom:to:with:startingAt:`; `indexOf:` and `=` over `array`.
- **Bound before, measure after**: collections-speed's `collections-sort` part with an OrderedCollection in place of the Array (a new row; it has none), sends per element before and after.
- **Risk and size**: `at:` with a Float or a LargeInteger index must still answer the same error: `OrderedCollectionTest`, and the extreme-integer habit applies in Smalltalk too (a test with `SmallInteger maxVal`, 0, -1, 1.5). Smalltalk tier. Small.
- **Confidence**: read.

### smalltalk.M13. Small per-call costs

Each is read from the code; none is worth a module alone.

| where | what | instead |
|---|---|---|
| `kernel/System/Smalltalk.class.st:111-119` | `classNamed:` rebuilds the whole name table (every class, `allBehaviors`, `reject:`, a new IdentityDictionary) on every miss of a name that is an interned Symbol, though `ClassBuilder` already calls `forgetClassNames` (`ClassBuilder.class.st:55`) | trust a miss; rebuild only when the table is nil |
| `kernel/Classes/Behavior.class.st:132-137,149-151` | `allSubclasses` and `subclasses` scan every class per call (`MethodTypeCheck>>signatureIsAnswered`, `TypeService>>invalidationOf:`, `TypeTable>>forget:`) | one pass that builds superclass to subclasses when a caller needs many |
| `kernel/Collections/Dictionary.class.st:137-142,201-206,28-33` | `keys`, `values`, `associations` fill an OrderedCollection with `add:` and copy it with `asArray` | fill an `Array new: tally` |
| `kernel/Collections/Collection.class.st:62-69` | `sorted` is `self asArray copy sort`: two copies for anything but an Array | copy only when `asArray` answered the receiver |
| `kernel/Text/String.class.st:10-15` | `asByteArray` is a `byteAt:` and an `at:put:` per byte | primitive 38 copies bytes from a byte object |
| `kernel/Text/String.class.st:139-155` | `lines` reads a Character at a time through a ReadStream and a WriteStream per line (about 8 sends a character) | `indexOfSubstring:` for LF and `copyFrom:to:` per line, CR handled at the cut |
| `kernel/Text/String.class.st:396-409` | `beginsWith:` and `endsWith:` compare with two `byteAt:` per byte (used per key of the checker's index and by the Tonel writer per method) | a compare-at-offset primitive if a counter shows them; else leave |
| `kernel/Text/Symbol.class.st:67-75` | `printOn:` makes three passes with `allSatisfy:` and a String `includes:` per character | one byte loop |
| `kernel/Text/Symbol.class.st:13-15` | `asString` is `'' , self`, per instance-variable name per method in the checker and the compiler | settled as "left" by collections-speed's question 1 for the benchmark; M10 (4) removes the hot caller |
| `kernel/UI/TextView.class.st:90-97` | `selection` gets a String "start stop" from the host and parses it with `substrings` and `asInteger` | the host answers an Array of two SmallIntegers (primitive 150 carries plain values) |
| `kernel/UI/Window.class.st` (`frame`) | four view calls for one rectangle (0.02 ms each, ADR 0010) | one `get: 'frame'` |
| `kernel/Streams/PositionableStream.class.st:56-61,116-129` | `next:`, `upTo:`, `upToEnd` copy element by element through a WriteStream | on a String, `copyFrom:to:` between two offsets |
| `kernel/Compiler/Compiler.class.st:259-272,238-245` | names compared as Strings: three `=` for `self`, `super`, `thisContext`, then each declared variable, then each instance variable, per variable reference | Symbols from the Scanner (with M5) |
| `types/Model/Type.class.st` (`dynamic`, `nilType`, `of:`) | a new Type object per literal, per statement list and per Dynamic answer | young garbage, cheap; one shared Dynamic and Nil only if a profile asks |

## Architecture

### smalltalk.A1. What is known of a class lives in six tables that must be kept in step

- **Where**: `kernel/System/Smalltalk.class.st:5-16` (`sources`, `classNames`, `definitions`, `organizations`, `undeclared`, `packages`, `classTypes`), `:541-551` (`forgetClass:`), and the `note…`/`forget…` pairs at `:50-71`, `:346-354`, `:518-672`.
- **What is there now**: six IdentityDictionaries keyed by class or behavior, each with its own `note`, `forget` and read methods, each read under the registry lock (M7). `forgetClass:` names five of them and the class-name table; `classTypes` was added to it with Types 1.
- **The cost**: a new fact about a class is a new table, three methods and a line in `forgetClass:`; forgetting the line leaves a removed class's data rooted (the class object stays as `AnObsoleteFoo`, so nothing collects it). A reader that wants two facts of one class (`packageOfSelector:in:` wants the method's package and then the class's definition) takes the lock twice and probes three tables. A redefinition must move the right subset (`replaceSources:of:` exists for one table because method identities change).
- **The proposal**: one `ClassRecord` per class (definition, both sides' sources, categories and packages, types, undeclared bindings) in one table; `forgetClass:` is one `removeKey:`. The read methods stay as they are named and become one probe and a slot read. `ClassDefinition` is the natural seed: it is already per class and immutable in use.
- **Bound and measure**: no performance bound is needed to justify it; M7's counters show the reads it saves. The test is a removal: after `removeClass:`, no table names the class (a walk with `pointersTo`).
- **Risk and size**: the image build hands the tables over through `recordDefinitions:`, `recordSources:`, `recordClassTypes:`, `recordSignatures:` (their formats are the bootstrap's side too: `Sources/KajoCompiler`), a release image must keep holding what it holds today (the strip question of types-1's record), and saved images change shape: an image version or a rebuild. Smalltalk tier plus the image build's Swift side if the hand-over changes; `ReflectionTest`, `LiveClassTest`, `OrganizationTest`, `TonelTest`. Medium.
- **Confidence**: read.

### smalltalk.A2. The tools' models hold the protocol's JsonObjects as their data

- **Where**: `tools/Models/BrowserModel.class.st:265-333` (`classNames`, `classOfId:`, `classTree`, `setHierarchy:`, `visibleEntries`), `:361-379` (`diagnosedSelectors`, `diagnostics`), `:496-512`; `tools/Windows/BrowserWindow.class.st:135-148`; `tools/Windows/InspectorWindow.class.st:58`; `kernel/Development/JsonObject.class.st:17-22`.
- **What is there now**: a reply's objects are kept and read where they are used: `(e at: 'package') = package` in `visibleEntries`, `e at: 'tag'`, `e at: 'name'`, `d at: 'selector'`, `d at: 'start'`. `JsonObject>>at:` is `keys indexOf: aKey asString`, a linear search with a String compare per key. `classTree` by tag runs `visible select: [:e | (e at: 'tag') = t]` once per tag.
- **The cost**: two modules know the reply's member names: the handler in the target and every model and window method that reads an entry; a renamed or added member is found by running. Mechanically, each access is 10 to 20 sends, on the UI Process: `visibleEntries` over 2000 classes is about 60 000 sends per call and it is called by `classNames` and `classTree`; the by-tag tree is (tags x classes) accesses. `BrowserModel>>selectors` (`:109-117`) is the same kind of recomputation: it flattens and sorts on every call, and a class selection calls it several times (`showSelectors`, `update: #selector`, the select handler, again on the diagnostics reply).
- **The proposal**: convert at the boundary: `setHierarchy:` makes one small record per class (a 4-slot Array or a `ClassEntry` with accessors) and groups by package and by tag once; the diagnostics reply becomes records in `diagnosticsIn:` (which already validates each one). `selectors` is cached and dropped where `selectorsByCategory` or `category` changes.
- **Bound before, measure after**: sends of `BrowserModelTest`'s population with 2000 classes (the fake client can serve them), before and after; the scripted session's "populate" and "select 10" steps.
- **Risk and size**: the tests read the models, not the JsonObjects, mostly; `BrowserModelTest` (435 lines) and `ToolsTests.swift`. Smalltalk tier. Small to medium.
- **Confidence**: read.

### smalltalk.A3. The checker's experiment switches and counters are in the product path

- **Where**: `types/Checker/TypeChecker.class.st:11-30,148-165` (`genericMethods`, `nilStrict`, `overloads`, `covariant`, `inferReturns`, `typeTests`, `memberwiseNil`, `genericClasses`, `recordTypes`, `counts`), `:34-36`; `types/Checker/MethodTypeCheck.class.st:279,282,494-495,802` (`checker count: '…' , …`), `:450-456` (`countSend:…`), and the tests of a switch at `:190,197,207,277,344,385,392-393,437,488,490`.
- **What is there now**: eight switches the experiment used to measure what each feature buys, each read per node or per send, and a `counts` Dictionary bumped with a String key that is concatenated at the call. `TypeService` makes `TypeChecker new` and sets none of them; `grep` finds each setter in one test file and nowhere in product code (`genericClasses:` in none).
- **The cost**: a mode nothing uses is a path nothing gates: `covariant` on, `nilStrict` off or `overloads` off are checker behaviours no product run and at most one test reaches, and every change of the checker has to keep them working or break them unseen. Mechanically it is a send per test and, where it counts, a concatenation and a String-keyed `at:put:` per ifNil-family node, per polymorphic send and per narrowed read, in a pass that takes 1.7 s.
- **The proposal**: the decisions are recorded (records 43 to 45): remove the switches whose answer is settled, with their dead branches; keep the counters behind one `counting` flag that a measurement sets, or in a subclass `MeasuringTypeCheck` that overrides `countSend:…` and `note…`. If a switch is still an open question, name it in the record and keep only that one.
- **Bound and measure**: none needed for the removal; the 81 diagnostics by class (types-3) must be unchanged, and the experiment's tables are in `experiments/optional-types/` for whoever asks again.
- **Risk and size**: `types/Tests/TypeCheckerTest.class.st` uses each setter once; those tests go or move with the measuring subclass. Smalltalk tier. Small.
- **Confidence**: read; "settled" is my reading of AGENTS.md's summary of records 43 to 45, which I did not read whole.

### smalltalk.A4. Forms only a measurement uses, and a batch size left from the one-block limit

- **Where**: `kernel/UI/TableView.class.st:59-74,87-103` (`rowCount:`, `rows:at:`, `send:then:head:rows:`), `kernel/UI/OutlineView.class.st:36-39,77-90`; `tools/Windows/BrowserWindow.class.st:162-177,241-250` (`treeForm`, `expand:`); `kernel/Development/DevSession.class.st:268-280` (`packageSelectors:`), `tools/Client/DevClient.class.st:436-437`.
- **What is there now**: the on-demand table (`rowCount:`, `rows:at:`, `onPage:`) has no caller in `tools/`; the on-demand tree is chosen by `BrowserWindow treeForm: #onDemand`, "the measurement's alternative"; `package.selectors` is sent by no model. Both wrappers split a push into calls of 4000 cells or 1300 triples, "from when an Array held at most 4095 values": each batch is copied into an OrderedCollection with an `add:` per cell, then `asArray`, then `{aName} , anArray` in `View>>call:with:`. `TableView>>list:` wraps every String in a one-element Array that the flattening unwraps.
- **The cost**: the owner's answer was "push by default and on demand for long lists" (record 07), and the one long list measured (19 866 rows: 68 to 117 ms pushed against 10 to 18 on demand, ADR 0010) is pushed by nothing and paged by nothing: the decision has no user, and the on-demand code has no product path that would notice it breaking (the hosts' paging callbacks included). The batching is two copies of one loop for a limit module 10 removed; its Smalltalk cost is small beside the host's (about 16 sends a row of the 3.4 to 5.9 µs a row the ADR's numbers give).
- **The proposal**: decide once: either a list in the tools switches to the on-demand form above a row count (senders of a common selector, a diagnostics list of the image are the candidates), or the on-demand forms and `treeForm` leave the product and stay in the measurement's files. Independently: one call per push (the Array is the argument; the host's `addRows`/`addChildren`/`addTree` then have no caller), `list:` passing the Strings with a column count of 1, and the op name as its own argument of the primitive rather than `{aName} , anArray`.
- **Bound and measure**: the ADR's rows are the bound; after, the session's populate step and the hosts' tests modes (`ViewWrapperTest` asks the host what it supports).
- **Risk and size**: the hosts are Swift (`AppKitHost`, `UIKitHost`): Swift tier, both shells' tests modes and the iPhone's. Small in Smalltalk, medium with the hosts.
- **Confidence**: read for the callers (`grep`); the host side was not read (another reviewer's area).

## Reuse

### smalltalk.R1. The lexical rules of Smalltalk source are written in five places

- **Where**: `kernel/Compiler/Scanner.class.st` (tokens; identifiers by primitive 171, `:63-80`); `kernel/System/TonelReader.class.st:91-112` (`matchingBracket:`: strings, comments and `$x` skipped by hand), `:58-60` (`isIdentifierByte:`: any byte from 128 up); `kernel/System/Smalltalk.class.st:243-248` (`isIdentifier:`: `isLetter`, where "any scalar above 127 counts as a letter"); `kernel/Text/Character.class.st:88-91` (`isLetter`); `tools/Client/SourceColorer.class.st:8-20` (`commentsIn:…`); `kernel/System/TonelWriter.class.st:187-200` (`pragmasFrom:token:into:`); `tools/Windows/ToolWindow.class.st:106-109,138-147` (`isWordByte:`, `selectorIn:`).
- **What is there now**: one scanner that follows the bootstrap's rule exactly, and four readers that each know part of the syntax again: where a comment ends, that `$'` is not a string's start, what continues an identifier.
- **The cost**: the second review's F7 was this drift between the two compilers, and its fix made "the one identifier rule" a primitive; `Smalltalk isIdentifier:` and `TonelReader>>isIdentifierByte:` were not moved to it, so a class or variable name with a scalar above 127 that is not alphabetic passes the reader's check and is refused later by the primitive's rule with another message. A change to the syntax (Types 1 added `<` types and `:X`) has to be made in each: the AGENTS.md lesson "a syntax change is checked against every reader of source" names the Tonel readers; the colourer's comment walk and `matchingBracket:` are two more.
- **The proposal**: `Smalltalk isIdentifier:` and the Tonel reader's identifier test ask primitive 171 through `Scanner`; `matchingBracket:` is the Scanner counting `#leftBracket` and `#rightBracket` tokens from the body's start (it already skips strings, comments and character literals, and counts lines); the colourer gets comments from the scanner (M9); `ToolWindow>>selectorIn:` scans the selection's tokens.
- **Bound and measure**: the Tonel round trip (byte-identical) and `TonelTest`'s summaries against the bootstrap reader are the oracle; the time of `TonelReader read:` on the largest class file before and after (the Scanner per token against a byte loop: with M5 it should not be slower; say so with the number).
- **Risk and size**: the Tonel reader is "rule for rule" the Swift reader; a method body the Scanner refuses (an unterminated string inside a body) fails at another place than today, so the refusals' lines must be compared on the fixtures and by `fuzz syntax`. Smalltalk tier plus the syntax fuzzer. Medium.
- **Confidence**: read; the name example is reasoned from the two rules, not run.

### smalltalk.R2. The client restates every request by hand

- **Where**: `tools/Client/DevClient.class.st:338-499` (32 methods `classComment:comment:then:` …), `:650-686` (`requests`, a table of kind and selector); `kernel/Development/DevSession.class.st` (the `<devProtocol>` methods), `kernel/Development/DevProtocol.class.st` (`describe`, `argumentNamesOf:`); `tools/Tests/FakeDevClient.class.st`.
- **What is there now**: the target derives a request from a method and its argument names; the client has a hand-written method per request whose body is `self request: '<kind>' args: {'name'. value …} then: aBlock`, and a hand-kept table that `DevClientTest` compares with `DevProtocol describe` for the kinds.
- **The cost**: a request's argument renamed in `DevSession` (its argument names are the wire names) breaks the client at run time; the test compares kinds and selectors, not argument names. A new request is a method, a table row and a fake's answer. The models send `request: '<kind>' args:` themselves in 28 places; by `grep` of the wrappers' first keywords, 5 of the 32 have a sender in a model or a window.
- **The proposal**: the models send `request:args:then:` (they already do for most: `BrowserModel` calls `self request: 'class.selectors' args: …`), the 32 wrappers go, and the test compares, for every `request:` send in `tools/`, the kind and the argument names with `DevProtocol describe` (a walk over the methods' literals). Or keep the wrappers and generate the table from them.
- **Bound and measure**: none; a count of wrappers with no sender (`grep`) says how many go at once.
- **Risk and size**: `DevClientTest` (340 lines) and `FakeDevClient`. Smalltalk tier. Small.
- **Confidence**: read for the client; which wrappers have senders is from `grep`, not a full reading of every model.

### smalltalk.R3. `BrowserModel` writes its reply guards by hand

- **Where**: `tools/Models/BrowserModel.class.st:345-358` and `:418-435` (`diagnosticsAsking`, `diagnosticsAgain`), `:470-512` (`listAsking`, `listAgain`), `:619-627` (`c = className`), `:671-683` (`sourceToken` and `selector = aSelector`), `:421`, `:500`.
- **What is there now**: two copies of "at most one request outstanding; one wanted meanwhile is asked when the reply comes" (four instance variables, six methods), and four different tests of "the reply is for what is shown now".
- **The cost**: the next model with a refreshed list (the debugger's frames after a step, the inspector after an evaluation) writes a third. A reply path that forgets to clear `…Asking` on an error stops asking for good; the two copies each handle it, separately.
- **The proposal**: in `ToolModel`: `latest: aKey request: aKind args: anArray then: aBlock`, which keeps one token per key and runs the block only for the newest, and `coalesced: aKey request: … then: …`, which keeps one outstanding and one wanted. `BrowserModel` keeps its states (`marks`) and loses the bookkeeping.
- **Risk and size**: `BrowserModelTest` drives these paths through `FakeDevClient`. Smalltalk tier. Small.
- **Confidence**: read.

### smalltalk.R4. Tests wait by hand, bounded in six places and unbounded in four

- **Where**: bounded: `kernel/Tests/ExceptionTest.class.st:145`, `TranscriptTest.class.st:14,19`, `ViewWrapperTest.class.st:21,30`, `ViewTest.class.st:25`, `RegistryTest.class.st:16`. Unbounded: `kernel/Tests/DevelopmentTest.class.st:306,321,333`, `LiveClassTest.class.st:75` (`[…] whileFalse: [ProcessorScheduler yield]`).
- **What is there now**: `[done or: [Smalltalk microsecondClock > deadline]] whileFalse: [(Delay forMilliseconds: 10) wait]` with a deadline computed before it, six times with three different bounds; and four loops that yield until a condition holds, with no bound.
- **The cost**: the unbounded ones hang the test Process if the condition never comes (the lesson "a wait that runs out is a failed check"), and a yield loop is a worker at full speed, in gates that run under twelve busy loops. Each bounded copy picks its own number.
- **The proposal**: `TestCase>>waitUntil: aBlock` (one long bound, a failed assertion with the test's name when it runs out, a short Delay between looks) and `waitUntil:within:`; the ten sites use it.
- **Risk and size**: none beyond the tests themselves; `kernel-test` under the sanitizer and load is where a wrong bound shows. Smalltalk tier. Small.
- **Confidence**: read by `grep`; `kernel/Tests/` was skimmed, not read whole.

### smalltalk.R5. Eight class-side registries each write their own lock

- **Where**: `kernel/System/Smalltalk.class.st:718-722`; `kernel/Processes/Delay.class.st:84-113`; `kernel/Processes/Unwinding.class.st:13-63`; `kernel/Development/Debugger.class.st:17-142`; `kernel/Development/DevProtocol.class.st:160-270`; `kernel/UI/View.class.st:199-282`; `kernel/System/Transcript.class.st:13-76`; `types/Live/TypeService.class.st`.
- **What is there now**: each has a lock in a class-side variable, a table or two, and methods of the shape `^ lock critical: [table at: k ifAbsent: [nil]]`. Three start the lock lazily (`lock isNil ifTrue: [self initialize]`, `registryLock isNil ifTrue: [registryLock := Mutex new]`), five in `initialize`. `View` and `Transcript` use `Semaphore forMutualExclusion` (not re-entrant), the others a `Mutex`.
- **The cost**: M7's read cost is paid in each, and a cheaper read (publish on write) would have to be written eight times. The lazy starts are each a small race of their own on first use (two Processes can each make a lock); the image build's `initializeKernel` makes most of them moot, which is why nothing fails. The choice between a Semaphore and a Mutex is made per class without a stated reason: `View class>>at:` runs per event under a non-re-entrant lock.
- **The proposal**: a `LockedTable` (or `Registry`) object: `at:`, `at:put:`, `at:ifAbsentPut:`, `removeKey:`, `snapshot`, `do:` over a snapshot; its lock made with it. The eight classes hold one or two of them. M7's step 2 then changes one class.
- **Risk and size**: `RegistryTest` is the guard and should move to the helper. Saved images hold the old shapes: rebuild. Smalltalk tier. Medium (many small edits).
- **Confidence**: read for Smalltalk, Delay, Unwinding, View, Transcript, TypeService; `Debugger` and `DevProtocol` by `grep` of their `critical:` lines.

## Read and found good

- `WriteStream` after collections-speed: `nextPut:` on a String stream is the encoding primitive alone, `nextPutAll:` and `growTo:` copy with primitive 38, `readLimit` is brought up where it is read. Nothing to add but M11's callers.
- `Integer>>printString:` (digits counted, written from the right, no stream). `String>>do:`'s ASCII fast path.
- `SequenceableCollection>>do:`, `collect:`, `reverseDo:`, `with:do:` and `OrderedCollection>>do:` are `to:do:` loops over the backing store: one block activation per element, nothing allocated.
- `SequenceableCollection>>sort:`: a merge sort with insertion runs, two scratch Arrays for the whole sort, stable. The record's "no sort primitive" stands.
- `HashedCollection>>rehashTo:` fills the new table before it publishes; growth by doubling at three quarters.
- `BlockClosure>>on:do:` and `ensure:`: a protected block costs `on:do:`, `privateOn:do:`, `value` and one `retryMarker` send; no allocation beyond the caller's closures. The handler search is a frame walk in the VM. I found no `on:do:` or `ensure:` inside a per-element loop of the kernel's collections or streams.
- `Semaphore>>critical:` and `Mutex>>critical:` have the shape the second review asked for; their cost is in M7 where they are per read.
- `UIEventLoop`: one untimed wait per event, frame events dispatched before any registry lookup, an error handed to a new loop Process. `Delay>>wait` has no timed wait of its own.
- `TypeService`: two locks so a compile never waits for a check, untimed waits, one drain per wake-up, `TypeTable>>refresh:in:` so a changed body costs its own pattern.
- `DevClient`: a request's timeout through a seam the fake fires; resends keep their ids; one `JsonObject` per request.
- `ToolWindow`'s builders (`makeWindow:`, `table:at:`, `textAt:editable:`, `addStatusLine`, `pane:keys:action:`) already carry the windows' common layout; what repeats (five toolbars built inline, the row-to-item `between:and:` in five select handlers) is a few lines each.
- `apps/Shared/smalltalk`: the bench loads and the demo are small and direct; nothing to report.

## Not read, or read in part

- `kernel/Tests/`, `tools/Tests/`, `types/Tests/`: searched with `grep` for helpers, not read; `FakeDevClient` not read.
- `kernel/Classes/`: `Behavior` in part (the methods quoted); `Class`, `ClassBuilder`, `ClassDefinition`, `ClassDescription`, `ClassTypes`, `Metaclass`, `Binding` not read.
- `kernel/Methods/`: `BlockClosure` read; `Context`, `CompiledMethod`, `Pragma`, `PragmaIndex`, `Message` not read.
- `kernel/Numbers/`: `Integer` and `Magnitude` read, `SmallInteger` and `Number` in part; `Float`, `Fraction`, the LargeIntegers not read.
- `kernel/Compiler/`: `Scanner`, `Parser`, `Compiler`, `BytecodeGenerator` read; `CompilerScope` and `CompiledCode` in part; the node classes and `TempVariable` not read.
- `kernel/Development/`: `Json*` and `DevSession` to line 330 read, `DevProtocol`'s dispatch read; `DebugStop`, `Debugger`, `ClientTransport` and the rest of `DevSession` not read.
- `kernel/System/`: `Smalltalk`, `TonelWriter`, `Transcript` read, `TonelReader` to line 266; `TonelDocument`, `TonelLoader` not read.
- `kernel/UI/`: `View`, `UIEventLoop`, `UIEvent`, `TextView`, `TableView`, `OutlineView`, `Window`, `Menu`, `Toolbar` read; `Button`, `Label`, `Slider`, `SplitView`, `ScrollView` not read.
- `kernel/SUnit/`, `kernel/Exceptions/` other than `Exception`, `kernel/Processes/Process`, `ProcessorScheduler`, `Ephemeron` (selectors only), `kernel/Objects/` other than `Object`: not read.
- `tools/`: `DevClient` (receive and request paths, the table), `SourceColorer`, `ToolModel`, `BrowserModel`, `BrowserWindow`, `ToolWindow`, `TranscriptModel` read, every window's `build` read; `DebuggerModel`, `InspectorModel`, `TargetPickerModel`, `TestRunnerModel`, `WorkspaceModel`, `DevTools` (four methods) and the other windows' update methods not read.
- `types/`: `TypeTable`, `TypeChecker`, `TypeService`, `TypeScope` read, `MethodTypeCheck` read but for lines 805 to 815; `types/Model/` only `Type`'s class side; `TypeDiagnostic` not read.
- Docs: `collections-speed.md`, ADR 0010, records 02, 04, 07, 15, 23 and the second review's two reports read whole; `developer-ui.md`, `types-2.md`, `types-3.md` and `gate-speed.md` read where a search led; `kernel.md`, `kernel-image.md`, `kernel-live.md`, `live-classes.md`, `discoverability.md`, `types-1.md`, ADR 0013 and records 43 to 45 and 49 not read. A finding that touches what those decided (A3, A4) says so.
- No number in this report was measured by me.

## Bugs met on the way

Not looked for; each is where I was reading.

- `kernel/Processes/Monitor.class.st:12-14`: `critical:` is `mutex wait. ^ aBlock ensure: [mutex signal]`, the shape the second review's F12 fixed in `Semaphore` and `Mutex` (a Process terminated between the wait and the `ensure:` keeps the lock). And `:35-43`: a Process terminated while it waits on its condition Semaphore inside `Monitor>>wait` unwinds through `critical:`'s `ensure:` and signals a mutex it gave back, an excess signal that lets two Processes in. `SharedQueue` is built on it.
- `kernel/Collections/OrderedCollection.class.st:93-102`: M1 is a leak for any queue; listed here too because it is wrong, not only slow.
- `tools/Client/DevClient.class.st:163,264,310`: `latencies` gets a 2-element Array per reply and `outages` one per reconnect, and nothing trims either (the lesson "a log nothing trims is a leak in an app that runs for days"; the diagnostics event makes the tools ask after every change).
- `kernel/Streams/PositionableStream.class.st:28-31`: `contents` tests `isText` and does the same thing on both branches.
- `kernel/System/Smalltalk.class.st:243-248` against `kernel/Compiler/Scanner.class.st:63-80`: two identifier rules (R1); a name the first accepts and the second refuses is possible above U+007F.
- `kernel/Tests/DevelopmentTest.class.st:306,321,333` and `LiveClassTest.class.st:75`: unbounded yield loops (R4).
