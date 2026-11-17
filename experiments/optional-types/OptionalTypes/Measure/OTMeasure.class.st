"The experiment's measurements, run by `kajo run <image> --sources <dir>` (UndefinedObject>>run:of: reads the file `command` in that directory and sends its first word to this class). The side files are read from <dir>/annotations/<Class>.types and every report is written to <dir>/out/. Each report is plain text, one fact per line, with the numbers RESULTS.md quotes."
Class {
	#name : #OTMeasure,
	#superclass : #Object,
	#classVars : [
		'Completing'
	]
}

{ #category : #files }
OTMeasure class >> annotations [
	"Every side file there is, one per class, read in class-name order."
	| a |
	a := OTAnnotations new.
	self classesByName do: [:c |
		(Smalltalk primReadFile: 'annotations/' , c name , '.types') ifNotNil: [:text | a readString: text file: c name , '.types']].
	^ a
]

{ #category : #files }
OTMeasure class >> option [
	"The second word of the command file, a configure:as: name (#base without one)."
	| w |
	w := (Smalltalk primReadFile: 'command') substrings.
	^ w size > 1 ifTrue: [(w at: 2) asSymbol] ifFalse: [#base]
]

{ #category : #files }
OTMeasure class >> classesByName [
	^ Smalltalk allClasses asArray sort: [:a :b | a name <= b name]
]

{ #category : #files }
OTMeasure class >> write: aString to: aName [
	(Smalltalk primWriteFile: 'out/' , aName contents: aString) isNil ifTrue: [self error: 'cannot write out/' , aName]
]

{ #category : #slices }
OTMeasure class >> toolsSlice [
	"The client slice of tools/ (question 4): the models and the client, with no side file of their own."
	^ #(#BrowserModel #DebuggerModel #InspectorModel #TargetPickerModel #TestRunnerModel #ToolModel #TranscriptModel #WorkspaceModel #DevClient #SourceColorer)
		collect: [:n | Smalltalk classNamed: n]
]

{ #category : #counting }
OTMeasure class >> tally: checks into: aStream label: aString [
	"One line of counts over a list of method checks."
	| kinds n parsed clean sends known typed results withSig |
	kinds := Dictionary new.
	n := checks size.
	parsed := (checks select: [:c | c parsed]) size.
	clean := (checks select: [:c | c parsed and: [c diagnostics isEmpty]]) size.
	withSig := (checks select: [:c | c hasSignature]) size.
	sends := checks inject: 0 into: [:a :c | a + c sends].
	known := checks inject: 0 into: [:a :c | a + c knownSends].
	typed := checks inject: 0 into: [:a :c | a + c typedSends].
	results := checks inject: 0 into: [:a :c | a + c knownResults].
	checks do: [:c | c diagnostics do: [:d | kinds at: d kind put: (kinds at: d kind ifAbsent: [0]) + 1]].
	aStream nextPutAll: aString; nextPutAll: ' methods='; print: n; nextPutAll: ' parsed='; print: parsed;
		nextPutAll: ' withSignature='; print: withSig; nextPutAll: ' clean='; print: clean;
		nextPutAll: ' sends='; print: sends; nextPutAll: ' knownReceiver='; print: known;
		nextPutAll: ' typedBySignature='; print: typed; nextPutAll: ' knownResult='; print: results;
		nextPutAll: ' diagnostics='; print: (kinds inject: 0 into: [:a :x | a + x]).
	(kinds keys asArray sort: [:a :b | a <= b]) do: [:k | aStream nextPutAll: ' '; nextPutAll: k; nextPutAll: '='; print: (kinds at: k)].
	aStream nextPutAll: String lf
]

{ #category : #counting }
OTMeasure class >> check: classes with: aChecker [
	| out |
	out := OrderedCollection new.
	classes do: [:c | out addAll: (aChecker checkClass: c)].
	^ out
]

{ #category : #counting }
OTMeasure class >> sourceLineOf: aDiagnostic [
	| i cname sel b m lines |
	i := aDiagnostic where indexOfSubstring: '>>'.
	cname := aDiagnostic where copyFrom: 1 to: i - 1.
	sel := (aDiagnostic where copyFrom: i + 2 to: aDiagnostic where byteSize) asSymbol.
	b := (cname endsWith: ' class')
		ifTrue: [(Smalltalk classNamed: (cname copyFrom: 1 to: cname byteSize - 6)) class]
		ifFalse: [Smalltalk classNamed: cname].
	m := b compiledMethodAt: sel ifAbsent: [^ ''].
	lines := m sourceCode lines.
	(aDiagnostic line between: 1 and: lines size) ifFalse: [^ ''].
	^ (lines at: aDiagnostic line) trimmed
]

{ #category : #counting }
OTMeasure class >> dump: checks to: aName [
	| s |
	s := WriteStream on: String new.
	checks do: [:c | c diagnostics do: [:d |
		s print: d; nextPutAll: '    | '; nextPutAll: (self sourceLineOf: d); nextPutAll: String lf]].
	self write: s contents to: aName
]

{ #category : #measures }
OTMeasure class >> configure: aChecker as: aSymbol [
	"The switch settings the experiment compares; #base is the proposed language."
	aSymbol == #noGenericMethods ifTrue: [aChecker genericMethods: false].
	aSymbol == #nilLoose ifTrue: [aChecker nilStrict: false].
	aSymbol == #noOverloads ifTrue: [aChecker overloads: false].
	aSymbol == #covariant ifTrue: [aChecker covariant: true].
	aSymbol == #noInference ifTrue: [aChecker inferReturns: false].
	aSymbol == #noTypeTests ifTrue: [aChecker typeTests: false].
	aSymbol == #memberwiseNil ifTrue: [aChecker memberwiseNil: true].
	^ aChecker
]

{ #category : #measures }
OTMeasure class >> slice [
	"Question 3: the annotated kernel slice, every method of every class with a side file, with the proposed language; the diagnostics in full in out/slice-diagnostics.txt."
	| ann s checks t0 t1 checker |
	ann := self annotations.
	s := WriteStream on: String new.
	s nextPutAll: 'files='; print: ann infos size; nextPutAll: ' annotationLines='; print: ann lineCount;
		nextPutAll: ' signatures='; print: ann signatureCount; nextPutAll: ' variables='; print: ann ivarCount;
		nextPutAll: ' annotationErrors='; print: ann errors size; nextPutAll: String lf.
	ann errors do: [:e | s print: e; nextPutAll: String lf].
	t0 := Smalltalk microsecondClock.
	checker := OTChecker on: ann.
	checks := self check: (self classesByName select: [:c | (ann infoFor: c) notNil]) with: checker.
	t1 := Smalltalk microsecondClock.
	self tally: checks into: s label: 'slice'.
	s nextPutAll: 'narrowing counts (question 1):'.
	(checker counts keys asArray sort: [:a :b | a <= b]) do: [:k | s nextPutAll: ' ['; nextPutAll: k; nextPutAll: ']='; print: (checker counts at: k)].
	s nextPutAll: String lf.
	s nextPutAll: 'checkMs='; print: (t1 - t0) // 1000; nextPutAll: String lf.
	self dump: checks to: 'slice-diagnostics.txt'.
	self write: s contents to: 'slice.txt'
]

{ #category : #measures }
OTMeasure class >> matrix [
	"Questions 1, 2 and 4: the slice and the tools' client slice under each switch, with the kernel's side files and with none."
	| ann s slice t0 |
	ann := self annotations.
	slice := self classesByName select: [:c | (ann infoFor: c) notNil].
	s := WriteStream on: String new.
	#(#base #noGenericMethods #nilLoose #noOverloads #covariant #noInference #noTypeTests #memberwiseNil) do: [:k |
		t0 := Smalltalk microsecondClock.
		self tally: (self check: slice with: (self configure: (OTChecker on: ann) as: k)) into: s label: 'slice ' , k.
		self tally: (self check: self toolsSlice with: (self configure: (OTChecker on: ann) as: k)) into: s label: 'tools ' , k.
		s nextPutAll: 'ms='; print: (Smalltalk microsecondClock - t0) // 1000; nextPutAll: String lf].
	#(#base #noInference) do: [:k |
		self tally: (self check: slice with: (self configure: (OTChecker on: OTAnnotations new) as: k)) into: s label: 'slice noAnnotations ' , k.
		self tally: (self check: self toolsSlice with: (self configure: (OTChecker on: OTAnnotations new) as: k)) into: s label: 'tools noAnnotations ' , k].
	self dump: (self check: self toolsSlice with: (OTChecker on: ann)) to: 'tools-diagnostics.txt'.
	self write: s contents to: 'matrix.txt'
]

{ #category : #measures }
OTMeasure class >> image [
	"The whole image (kernel, tools, this package) with the proposed language: the time, the counts and the dependency index's size (question 5's starting point and the tables measured on the whole image)."
	| ann checker checks t0 t1 s edges biggest |
	ann := self annotations.
	checker := self configure: (OTChecker on: ann) as: self option.
	t0 := Smalltalk microsecondClock.
	checks := self check: self classesByName with: checker.
	t1 := Smalltalk microsecondClock.
	s := WriteStream on: String new.
	self tally: checks into: s label: 'image'.
	edges := 0.
	biggest := 0.
	checker index do: [:set | edges := edges + set size. biggest := biggest max: set size].
	s nextPutAll: 'checkMs='; print: (t1 - t0) // 1000; nextPutAll: ' indexKeys='; print: checker index size;
		nextPutAll: ' indexEdges='; print: edges; nextPutAll: ' largestDependents='; print: biggest; nextPutAll: String lf.
	s nextPutAll: 'narrowing counts (question 1):'.
	(checker counts keys asArray sort: [:a :b | a <= b]) do: [:k | s nextPutAll: ' ['; nextPutAll: k; nextPutAll: ']='; print: (checker counts at: k)].
	s nextPutAll: String lf.
	(checker index keys asArray sort: [:a :b | (checker index at: a) size >= (checker index at: b) size]) readStream in: [:rs |
		1 to: 15 do: [:i | | k | k := rs next. s nextPutAll: 'top '; nextPutAll: k; nextPutAll: ' '; print: (checker index at: k) size; nextPutAll: String lf]].
	self dump: checks to: 'image-diagnostics.txt'.
	self write: s contents to: 'image.txt'
]

{ #category : #live }
OTMeasure class >> liveChanges [
	"Question 5: ten method bodies recompiled (leaves) and ten signatures changed (widely used ones), {kind. class. selector. new side-file text or nil}."
	^ {
		{#body. Association. #key. nil}.
		{#body. Interval. #increment. nil}.
		{#body. Fraction. #numerator. nil}.
		{#body. Character. #isVowel. nil}.
		{#body. String. #trimmed. nil}.
		{#body. OrderedCollection. #removeFirst. nil}.
		{#body. Dictionary. #keysSortedSafely. nil}.
		{#body. Integer. #isPrime. nil}.
		{#body. WriteStream. #tab. nil}.
		{#body. Set. #hash. nil}.
		{#sig. Object. #printOn:. 'method printOn: <WriteStream[String]> ^<Self>'}.
		{#sig. Collection. #do:. 'method do: <[E, ^Object]> ^<Self>'}.
		{#sig. Object. #printString. 'method printString ^<String | Nil>'}.
		{#sig. Object. #=. 'method = <Object> ^<Boolean>'}.
		{#sig. SequenceableCollection. #at:. 'method at: <Integer> ^<E | Nil>'}.
		{#sig. Object. #error:. 'method error: <String> ^<Nil>'}.
		{#sig. Boolean. #ifTrue:. 'method ifTrue: <[^Dynamic]> ^<Dynamic>'}.
		{#sig. String. #,. 'method , <Object> ^<String>'}.
		{#sig. WriteStream. #nextPutAll:. 'method nextPutAll: <String> ^<String>'}.
		{#sig. OrderedCollection. #add:. 'method add: <E> ^<Self>'}}
]

{ #category : #live }
OTMeasure class >> live [
	"Question 5: the whole image checked once; then each change is made (a body recompiled with compile:, or a signature replaced in the side-file table) and only what read it is rechecked, on a background Process (priority 0) while this Process waits; the dependents, the time and the change in diagnostics, one line each, in out/live.txt."
	| ann checker s t0 diagCount |
	ann := self annotations.
	checker := OTChecker on: ann.
	t0 := Smalltalk microsecondClock.
	self check: self classesByName with: checker.
	s := WriteStream on: String new.
	diagCount := [checker results inject: 0 into: [:a :mc | a + mc diagnostics size]].
	s nextPutAll: 'full checkMs='; print: (Smalltalk microsecondClock - t0) // 1000; nextPutAll: ' methods='; print: checker results size; nextPutAll: ' diagnostics='; print: diagCount value; nextPutAll: String lf.
	self liveChanges do: [:c | | kind cls sel keys rechecked before after us sem b |
		kind := c first. cls := c at: 2. sel := c at: 3.
		before := diagCount value.
		b := cls.
		kind == #body ifTrue: [b compile: (b compiledMethodAt: sel) sourceCode].
		kind == #sig ifTrue: [
			(ann infoFor: cls) methods removeKey: sel ifAbsent: [nil].
			ann readString: 'class ' , cls name , String lf , (c at: 4) file: 'live'].
		sem := Semaphore new.
		[| u0 |
			u0 := Smalltalk microsecondClock.
			keys := kind == #body
				ifTrue: [(checker invalidate: 'body:' , (checker keyOf: sel in: b)) add: (checker keyOf: sel in: b); yourself]
				ifFalse: [checker invalidate: 'sig:' , cls name , '>>' , sel].
			rechecked := checker recheck: keys.
			us := Smalltalk microsecondClock - u0.
			sem signal] forkAt: 0.
		sem wait.
		after := diagCount value.
		s nextPutAll: kind; nextPutAll: ' '; nextPutAll: cls name; nextPutAll: '>>'; nextPutAll: sel;
			nextPutAll: ' dependents='; print: keys size; nextPutAll: ' rechecked='; print: rechecked size;
			nextPutAll: ' recheckUs='; print: us; nextPutAll: ' diagnostics='; print: before; nextPutAll: '->'; print: after; nextPutAll: String lf].
	self write: s contents to: 'live.txt'
]

{ #category : #scripting }
OTMeasure class >> scripting [
	"Question 9: protocols made by code from a scripting dictionary, workspace expressions checked against them, the dictionary replaced and the expressions that read it rechecked; out/scripting.txt."
	| ann checker s keys t0 rechecked |
	ann := self annotations.
	checker := OTChecker on: ann.
	s := WriteStream on: String new.
	t0 := Smalltalk microsecondClock.
	keys := OTScripting register: OTScripting dictionary in: ann.
	s nextPutAll: 'registered '; print: keys size; nextPutAll: ' protocols in us='; print: Smalltalk microsecondClock - t0; nextPutAll: String lf.
	OTScripting expressions doWithIndex: [:src :i | | mc |
		mc := checker checkSource: src named: 'doit' , i printString bindings: (Dictionary new at: 'app' put: (OTProtocolType named: 'Mail.Application'); yourself).
		s nextPutAll: 'v1 doit'; print: i; nextPutAll: ' ['; nextPutAll: src; nextPutAll: '] : '; print: mc inferredResult; nextPutAll: ' '; print: (mc diagnostics collect: [:d | d text]) asArray; nextPutAll: String lf].
	t0 := Smalltalk microsecondClock.
	keys := OTScripting register: OTScripting dictionaryVersion2 in: ann.
	rechecked := checker recheck: (keys inject: Set new into: [:set :k | set addAll: (checker invalidate: k); yourself]).
	s nextPutAll: 'replaced: rechecked '; print: rechecked size; nextPutAll: ' expressions in us='; print: Smalltalk microsecondClock - t0; nextPutAll: String lf.
	(rechecked asArray sort: [:a :b | a key <= b key]) do: [:mc |
		s nextPutAll: 'v2 '; nextPutAll: mc key; nextPutAll: ' : '; print: mc inferredResult; nextPutAll: ' '; print: (mc diagnostics collect: [:d | d text]) asArray; nextPutAll: String lf].
	self write: s contents to: 'scripting.txt'
]

{ #category : #proposals }
OTMeasure class >> proposalFor: aClass index: i checker: aChecker [
	"{type proposed from the values the instance variable holds in every instance (at most 3000). instances}"
	| insts t |
	insts := aClass allSubInstances: 3000.
	t := nil.
	insts := insts select: [:o | (Smalltalk instanceVariableNamesOf: o class) size >= i].
	insts do: [:o | | v ok |
		ok := true.
		v := [o instVarAt: i] on: Error do: [:e | ok := false. e return: nil].
		ok ifTrue: [t := aChecker join: t with: (v isNil ifTrue: [OTType nilType] ifFalse: [OTType of: v class])] ifFalse: [aChecker count: 'unreadable ' , o class name]].
	^ {t. insts size}
]

{ #category : #proposals }
OTMeasure class >> proposals [
	"Question 6: for every instance variable of the annotated slice and of the tools' client slice, the type its live values propose, beside the type the side file declares; and how homogeneous the image's collections are; then the argument classes the kernel's collection, number and stream tests pass to traced methods, beside the signatures. out/proposals.txt."
	| ann checker s tally homog |
	ann := self annotations.
	checker := OTChecker on: ann.
	s := WriteStream on: String new.
	tally := Dictionary new.
	((self classesByName select: [:c | (ann infoFor: c) notNil]) , self toolsSlice) do: [:c |
		(Smalltalk instanceVariableNamesOf: c) doWithIndex: [:n :i | | p written verdict |
			p := self proposalFor: c index: i checker: checker.
			written := ann ivarTypeOf: n asString in: c.
			verdict := (p last = 0 or: [p first isNil])
				ifTrue: [#noInstances]
				ifFalse: [written isNil
					ifTrue: [#unannotated]
					ifFalse: [((checker isSubtype: p first of: written) and: [checker isSubtype: written of: p first])
						ifTrue: [#same]
						ifFalse: [(checker isSubtype: p first of: written)
							ifTrue: [#proposalNarrower]
							ifFalse: [(checker isSubtype: written of: p first) ifTrue: [#proposalWider] ifFalse: [#disagree]]]]].
			tally at: verdict put: (tally at: verdict ifAbsent: [0]) + 1.
			s nextPutAll: c name; nextPutAll: '.'; nextPutAll: n; nextPutAll: ' instances='; print: p last;
				nextPutAll: ' proposed='; print: p first; nextPutAll: ' written='; print: written; nextPutAll: ' '; nextPutAll: verdict; nextPutAll: String lf]].
	s nextPutAll: 'unreadable: '; print: checker counts; nextPutAll: String lf.
	s nextPutAll: 'instance variables:'.
	(tally keys asArray sort: [:a :b | a <= b]) do: [:k | s nextPutAll: ' '; nextPutAll: k; nextPutAll: '='; print: (tally at: k)].
	s nextPutAll: String lf.
	{OrderedCollection. Array. Set. Dictionary} do: [:c |
		homog := Dictionary new.
		(c allInstances: 3000) do: [:col | | t k |
			t := nil.
			col do: [:e | t := checker join: t with: (e isNil ifTrue: [OTType nilType] ifFalse: [OTType of: e class])].
			k := t isNil ifTrue: [#empty] ifFalse: [
				(t isClassType and: [t cls ~~ Object]) ifTrue: [(col allSatisfy: [:e | e class == t cls]) ifTrue: [#oneClass] ifFalse: [#commonSuperclass]] ifFalse: [
				(t isUnion and: [t includesNil and: [t withoutNil isClassType and: [t withoutNil cls ~~ Object]]]) ifTrue: [#oneClassAndNil] ifFalse: [#mixed]]].
			homog at: k put: (homog at: k ifAbsent: [0]) + 1].
		s nextPutAll: 'elements of '; nextPutAll: c name; nextPutAll: ':'.
		(homog keys asArray sort: [:a :b | a <= b]) do: [:k | s nextPutAll: ' '; nextPutAll: k; nextPutAll: '='; print: (homog at: k)].
		s nextPutAll: String lf].
	self write: s contents to: 'proposals.txt'.
	self traceRun: ann checker: checker
]

{ #category : #proposals }
OTMeasure class >> traceRun: ann checker: checker [
	"Question 6, second half: trace the annotated methods (with arguments) of a few classes, run the kernel's tests of those classes, compare the classes seen with the signatures' parameter types. out/trace.txt."
	| s traced suite result tally |
	s := WriteStream on: String new.
	traced := 0.
	{Association. Interval. OrderedCollection. Dictionary. Set. Fraction. Character. Integer. String. WriteStream. ReadStream} do: [:c |
		(ann infoFor: c) methods keysDo: [:sel | (OTTrace trace: sel in: c) ifTrue: [traced := traced + 1]]].
	suite := TestSuite named: 'trace'.
	#(#ArrayTest #DictionaryTest #IntervalTest #OrderedCollectionTest #SetTest #StreamTest #StringTest #FractionTest #IntegerTest #CharacterTest #SymbolTest)
		do: [:n | (Smalltalk classNamed: n) suite tests do: [:t | suite addTest: t]].
	result := suite run.
	s nextPutAll: 'traced methods='; print: traced; nextPutAll: ' tests='; print: suite tests size;
		nextPutAll: ' passed='; print: result passed size; nextPutAll: ' failures='; print: result failures size; nextPutAll: ' errors='; print: result errors size; nextPutAll: String lf.
	tally := Dictionary new.
	(OTTrace seen keys asArray sort: [:a :b | a <= b]) do: [:k | | i cls sel sig classes |
		i := k indexOfSubstring: '>>'.
		cls := Smalltalk classNamed: (k copyFrom: 1 to: i - 1).
		sel := (k copyFrom: i + 2 to: k byteSize) asSymbol.
		sig := (ann infoFor: cls) methods at: sel ifAbsent: [nil].
		sig notNil ifTrue: [
			classes := OTTrace seen at: k.
			1 to: classes size do: [:j | | p seenT verdict |
				p := sig last argTypes at: j.
				seenT := nil.
				(classes at: j) ifNotNil: [:set | set do: [:x | seenT := checker join: seenT with: (x == UndefinedObject ifTrue: [OTType nilType] ifFalse: [OTType of: x])]].
				verdict := seenT isNil ifTrue: [#notSeen] ifFalse: [
					| hasVar | hasVar := false. p varsDo: [:v | hasVar := true].
					(hasVar or: [p isBlockType or: [p isDynamic]]) ifTrue: [#genericOrBlock] ifFalse: [
					(checker isSubtype: seenT of: p)
						ifTrue: [(checker isSubtype: p of: seenT) ifTrue: [#same] ifFalse: [#declaredWider]]
						ifFalse: [#seenOutsideDeclared]]].
				tally at: verdict put: (tally at: verdict ifAbsent: [0]) + 1.
				s nextPutAll: k; nextPutAll: ' arg'; print: j; nextPutAll: ' declared='; print: p; nextPutAll: ' seen='; print: seenT; nextPutAll: ' '; nextPutAll: verdict; nextPutAll: String lf]]].
	s nextPutAll: 'arguments:'.
	(tally keys asArray sort: [:a :b | a <= b]) do: [:k | s nextPutAll: ' '; nextPutAll: k; nextPutAll: '='; print: (tally at: k)].
	s nextPutAll: String lf.
	self write: s contents to: 'trace.txt'
]

{ #category : #completion }
OTMeasure class >> percentiles: aCollection into: aStream label: aString [
	| a |
	a := aCollection asArray sort: [:x :y | x <= y].
	a isEmpty ifTrue: [^ self].
	aStream nextPutAll: aString; nextPutAll: ' n='; print: a size;
		nextPutAll: ' p50='; print: (a at: (a size + 1) // 2);
		nextPutAll: ' p90='; print: (a at: ((a size * 9 + 9) // 10 min: a size));
		nextPutAll: ' max='; print: a last; nextPutAll: String lf
]

{ #category : #completion }
OTMeasure class >> selectorsFor: aType [
	"Question 8: what a completion popup lists for a receiver of aType: each selector it answers, with its signature when one is written (an Array of {selector. signature or nil})."
	| out c seen |
	out := OrderedCollection new.
	seen := IdentitySet new.
	aType isClassType ifFalse: [^ #()].
	c := aType cls.
	[c notNil] whileTrue: [
		c selectors do: [:sel | (seen includes: sel) ifFalse: [
			seen add: sel.
			out add: {sel. (Completing signaturesFor: sel meta: false from: aType cls) ifNotNil: [:f | f last last]}]].
		c := c superclass].
	^ out asArray
]


{ #category : #completion }
OTMeasure class >> completion [
	"Question 8: the questions a browser, a completion popup and an MCP client would ask, timed in microseconds on the tools' client slice with the kernel's side files: the type of every expression of a method (one check with types recorded), the type at a source offset (a lookup in that record), the selectors a receiver answers, the diagnostics of a class, the dependents of a change. out/completion.txt."
	| ann checker s methodUs lookupUs selectorUs classUs depUs counts types |
	ann := self annotations.
	Completing := ann.
	checker := OTChecker on: ann.
	checker recordTypes: true.
	s := WriteStream on: String new.
	methodUs := OrderedCollection new. lookupUs := OrderedCollection new. selectorUs := OrderedCollection new.
	classUs := OrderedCollection new. depUs := OrderedCollection new. counts := OrderedCollection new.
	types := OrderedCollection new.
	self toolsSlice do: [:c | | t0 |
		t0 := Smalltalk microsecondClock.
		checker checkClass: c.
		classUs add: Smalltalk microsecondClock - t0].
	self toolsSlice do: [:c | c selectors do: [:sel | | t0 mc |
		t0 := Smalltalk microsecondClock.
		mc := checker check: sel in: c.
		methodUs add: Smalltalk microsecondClock - t0.
		(mc types anySatisfy: [:r | r first notNil]) ifTrue: [ | off |
			off := (mc types detect: [:r | r first notNil]) first + 1.
			t0 := Smalltalk microsecondClock.
			(mc types inject: nil into: [:best :r | (((r first notNil and: [r first <= off]) and: [off < (r at: 2)]) and: [best isNil or: [(r at: 2) - r first < ((best at: 2) - best first)]]) ifTrue: [r] ifFalse: [best]]).
			lookupUs add: Smalltalk microsecondClock - t0].
		mc types do: [:r | (r at: 3) isClassType ifTrue: [types add: (r at: 3)]]]].
	(types asArray copyFrom: 1 to: (types size min: 300)) do: [:t | | t0 sels |
		t0 := Smalltalk microsecondClock.
		sels := self selectorsFor: t.
		selectorUs add: Smalltalk microsecondClock - t0.
		counts add: sels size].
	checker index keysDo: [:k | | t0 |
		t0 := Smalltalk microsecondClock.
		checker dependentsOf: k.
		depUs add: Smalltalk microsecondClock - t0].
	self percentiles: methodUs into: s label: 'typesOfAMethodUs'.
	self percentiles: lookupUs into: s label: 'typeAtOffsetUs'.
	self percentiles: selectorUs into: s label: 'selectorsOfAReceiverUs'.
	self percentiles: counts into: s label: 'selectorsListed'.
	self percentiles: classUs into: s label: 'diagnosticsOfAClassUs'.
	self percentiles: depUs into: s label: 'dependentsOfAChangeUs'.
	self write: s contents to: 'completion.txt'
]
