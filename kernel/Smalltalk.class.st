"The system: the classes, their definitions (ClassDefinition, handed over by the image build and kept by the class definition protocol, module 8e), every method's source and category, the kernel's initialization, and the entry point kajo run and kajo test start at (the image names this class in its special objects; each run starts a fresh Process sending run:of:, setup: or test: to it)."
Class {
	#name : #Smalltalk,
	#superclass : #Object,
	#classInstVars : [
		'sources',
		'classNames',
		'definitions',
		'organizations',
		'undeclared'
	],
	#category : #'Kernel-System'
}

{ #category : #'class variables' }
Smalltalk class >> forgetUndeclared: aSymbol in: aClass [
	undeclared isNil ifTrue: [^ nil].
	^ (undeclared at: aClass ifAbsent: [^ nil]) removeKey: aSymbol ifAbsent: [nil]
]

{ #category : #'class variables' }
Smalltalk class >> noteUndeclared: aBinding in: aClass [
	undeclared isNil ifTrue: [undeclared := IdentityDictionary new].
	(undeclared at: aClass ifAbsentPut: [IdentityDictionary new]) at: aBinding key put: aBinding
]

{ #category : #'class variables' }
Smalltalk class >> undeclaredBinding: aSymbol in: aClass [
	"A Binding for a class variable aSymbol of aClass about to be declared: the one removed from aClass earlier, if any (so the methods that hold it work again), else a new one."
	undeclared isNil ifFalse: [
		((undeclared at: aClass ifAbsent: [nil]) ifNotNil: [:d | d at: aSymbol ifAbsent: [nil]]) ifNotNil: [:b | ^ b]].
	^ Binding new key: aSymbol
]

{ #category : #classes }
Smalltalk class >> allBehaviors [
	"Every class and metaclass in the class table."
	| out |
	out := OrderedCollection new.
	1 to: self classCount do: [:i | (self classAt: i) ifNotNil: [:c | out add: c]].
	^ out
]

{ #category : #classes }
Smalltalk class >> allClasses [
	"Every class but the removed ones (module 8e)."
	^ self allBehaviors reject: [:c | c isMeta or: [c isObsolete]]
]

{ #category : #classes }
Smalltalk class >> at: aSymbol [
	^ self at: aSymbol ifAbsent: [KeyNotFound new key: aSymbol; signal: 'no class ' , aSymbol]
]

{ #category : #classes }
Smalltalk class >> at: aSymbol ifAbsent: aBlock [
	^ (self classNamed: aSymbol) ifNil: [aBlock value]
]

{ #category : #classes }
Smalltalk class >> classAt: anIndex [
	<primitive: 118>
	^ nil
]

{ #category : #classes }
Smalltalk class >> classCount [
	<primitive: 119>
	^ 0
]

{ #category : #classes }
Smalltalk class >> classNamed: aString [
	"The class named aString, or nil (a table by name, rebuilt when a class is missing from it)."
	| sym |
	sym := Symbol lookup: aString.
	sym isNil ifTrue: [^ nil].
	classNames isNil ifTrue: [self rebuildClassNames].
	^ classNames at: sym ifAbsent: [
		self rebuildClassNames.
		classNames at: sym ifAbsent: [nil]]
]

{ #category : #classes }
Smalltalk class >> classesSuperclassesFirst [
	"Every class, each after its superclass, classes at the same depth by name."
	| depth |
	depth := IdentityDictionary new.
	^ self allClasses asArray sort: [:a :b | | da db |
		da := depth at: a ifAbsentPut: [a allSuperclasses size].
		db := depth at: b ifAbsentPut: [b allSuperclasses size].
		da < db or: [da = db and: [a name <= b name]]]
]

{ #category : #classes }
Smalltalk class >> forgetClassNames [
	classNames := nil
]

{ #category : #classes }
Smalltalk class >> includesKey: aSymbol [
	^ (self at: aSymbol ifAbsent: [nil]) notNil
]

{ #category : #classes }
Smalltalk class >> rebuildClassNames [
	classNames := IdentityDictionary new.
	self allClasses do: [:c | classNames at: c name put: c]
]

{ #category : #classes }
Smalltalk class >> removeClass: aClass [
	"Remove aClass (module 8e; ClassBuilder remove:)."
	^ ClassBuilder remove: aClass
]

{ #category : #classes }
Smalltalk class >> removeClassNamed: aName [
	^ self removeClass: (self at: aName asSymbol)
]

{ #category : #'entry points' }
Smalltalk class >> garbageCollect [
	<primitive: 11>
	^ nil
]

{ #category : #'entry points' }
Smalltalk class >> microsecondClock [
	<primitive: 141>
	^ 0
]

{ #category : #'entry points' }
Smalltalk class >> run: worker of: workers [
	"kajo run <image> --workers n: each worker's Process starts here."
	(nil respondsTo: #run:of:) ifTrue: [^ nil perform: #run:of: with: worker with: workers].
	Transcript show: 'Kajo: nothing to run (UndefinedObject>>run:of: is not defined)'; cr.
	^ 0
]

{ #category : #'entry points' }
Smalltalk class >> setup: workers [
	(nil respondsTo: #setup:) ifTrue: [nil perform: #setup: with: workers].
	^ 0
]

{ #category : #'entry points' }
Smalltalk class >> test: arguments [
	"kajo test <image> [--filter pattern] [--tag tag]: run the matching TestCases, emitting the event stream. Answers the number of failures and errors."
	| filter tag i |
	i := 1.
	[i <= arguments size] whileTrue: [
		(arguments at: i) = '--filter' ifTrue: [filter := arguments at: i + 1. i := i + 1].
		(arguments at: i) = '--tag' ifTrue: [tag := arguments at: i + 1. i := i + 1].
		i := i + 1].
	^ TestRunner new runFilter: filter tag: tag
]

{ #category : #'entry points' }
Smalltalk class >> testFilter: aPatternOrNil tag: aTagOrNil [
	"The shells' tests mode (module 9a): test: without an Array of arguments."
	^ TestRunner new runFilter: aPatternOrNil tag: aTagOrNil
]

{ #category : #'file in' }
Smalltalk class >> isIdentifier: aString [
	"A letter or _ first, then letters, digits and _ (the bootstrap compiler's rule for ASCII; any scalar above 127 counts as a letter)."
	aString isEmpty ifTrue: [^ false].
	(aString first isLetter or: [aString first = $_]) ifFalse: [^ false].
	^ aString allSatisfy: [:c | c isLetter or: [c isDigit or: [c = $_]]]
]

{ #category : #'file in' }
Smalltalk class >> methodListsOf: anArray [
	"For each class anArray names, its methods (both sides, by selector): selector, bytecodes, literal count, header (a test compares two images)."
	^ anArray collect: [:n | | c out |
		c := self at: n asSymbol.
		out := ''.
		(Array with: c with: c class) do: [:b |
			(b selectors asArray sort: [:x :y | x <= y]) do: [:sel | | m |
				m := b compiledMethodAt: sel.
				out := out , b name , '>>' , sel , ' ' , m bytecodes printString , ' ' , m literals size printString , ' ' , m numArgs printString , ' ' , m numTemps printString , ' ' , m primitive printString , String lf]].
		out]
]

{ #category : #'file in' }
Smalltalk class >> readTonel: aString [
	"Define or redefine the class one Tonel file holds and install its methods (module 8e): the file is the class, so a method of the class the file does not hold is removed. A new class is defined, then its methods compiled; an existing one (of the same superclass) is redefined in one step whose new methods are the file's, made against the new shape, and its subclasses' recompiled. Answers the class."
	^ TonelLoader load: (TonelReader read: aString)
]

{ #category : #'file in' }
Smalltalk class >> readTonelAll: anArray [
	"readTonel: each text in turn; answer what each class writes out afterwards."
	^ anArray collect: [:t | (self readTonel: t) tonelSource]
]

{ #category : #'file in' }
Smalltalk class >> tonelSourcesOf: anArray [
	"The Tonel file of each class anArray names (a test's way out of the image)."
	^ anArray collect: [:n | (self at: n asSymbol) tonelSource]
]

{ #category : #'file in' }
Smalltalk class >> tonelSummaries: anArray [
	"For each Tonel text, its TonelReader summary (a test compares them with the bootstrap reader's)."
	^ anArray collect: [:t | (TonelReader read: t) summary]
]

{ #category : #'file out' }
Smalltalk class >> readTonelFile: aPath [
	"The text of the file aPath names under the directory the VM was opened with."
	^ (self primReadFile: aPath) ifNil: [self error: 'cannot read ' , aPath]
]

{ #category : #'file out' }
Smalltalk class >> writeAllTonel [
	"writeTonel: into the opened directory itself."
	^ self writeTonel: ''
]

{ #category : #'file out' }
Smalltalk class >> writeTonel: aDirectory [
	"Write every class, sealed ones too, as <Name>.class.st into aDirectory, a path under the directory the VM was opened with (kajo run --sources; '' for that directory itself). Answers how many files. Module 8e."
	| n |
	n := 0.
	self allClasses do: [:c | TonelWriter write: c into: aDirectory. n := n + 1].
	^ n
]

{ #category : #initialization }
Smalltalk class >> initializeKernel [
	"Run by the image build before the image is saved: each class's own class-side initialize, superclasses first, then the pragma index."
	self classesSuperclassesFirst do: [:c |
		(c class includesSelector: #initialize) ifTrue: [c initialize]].
	Pragma rebuildIndex.
	Ephemeron forgetProcess
]

{ #category : #primitives }
Smalltalk class >> primDefineClass: anArray [
	"A class from its specification (ClassBuilder), or a String saying why not (module 8e). Fails in a release image."
	<primitive: 145>
	Smalltalk isReleaseImage ifTrue: [^ InstallForbidden new behavior: nil selector: (anArray at: 1); signal].
	^ self error: 'the VM refused to define a class'
]

{ #category : #primitives }
Smalltalk class >> primReadFile: aPath [
	"The UTF-8 text of the file aPath names under the opened directory, or nil."
	<primitive: 149>
	^ nil
]

{ #category : #primitives }
Smalltalk class >> primRedefine: anArray [
	"Reshape, recompile and re-pool classes in one stop (ClassBuilder): nil, or a String saying why not (module 8e). Fails in a release image."
	<primitive: 146>
	Smalltalk isReleaseImage ifTrue: [^ InstallForbidden new behavior: nil selector: nil; signal].
	^ self error: 'the VM refused to redefine a class'
]

{ #category : #primitives }
Smalltalk class >> primRemoveClass: aClass as: anObsoleteName [
	"Unbind aClass (ClassBuilder): nil, or a String saying why not (module 8e). Fails in a release image."
	<primitive: 147>
	Smalltalk isReleaseImage ifTrue: [^ InstallForbidden new behavior: aClass selector: nil; signal].
	^ self error: 'the VM refused to remove ' , aClass printString
]

{ #category : #primitives }
Smalltalk class >> primWriteFile: aPath contents: aString [
	"Replace (or create) the file aPath names, a path under the directory the VM was opened with (no absolute path, no . or .. component, no way out through a link), with aString: true, or nil when refused or failed. Fails in a release image and without a directory (module 8e)."
	<primitive: 148>
	^ nil
]

{ #category : #snapshots }
Smalltalk class >> primSnapshot: aPathOrNil [
	"Fails outside a VM, while another save is in progress, when the saved stacks do not fit the heap, or when the file cannot be written."
	<primitive: 142>
	^ self error: 'the image could not be saved'
]

{ #category : #snapshots }
Smalltalk class >> resumeAfterSnapshot [
	"The image resumed in a new VM: arm again what lived in the old one's host (the Delays' timers) and make sure the finalization Process exists. The Transcript and the event stream go to the new host by themselves."
	Delay resumeAfterSnapshot.
	Ephemeron resumeAfterSnapshot.
	View resumeAfterSnapshot.
	UIEventLoop resumeAfterSnapshot
]

{ #category : #snapshots }
Smalltalk class >> snapshot: aPathOrNil [
	"Save the image with every Process in it: to the file aPathOrNil names, or, given nil, to the VM's host. Answers false here; the saved image resumes this Process with true, after the hook that re-arms what the VM does not save (module 8c)."
	| resumed |
	Delay prepareSnapshot.
	resumed := self primSnapshot: aPathOrNil.
	resumed ifTrue: [self resumeAfterSnapshot].
	^ resumed
]

{ #category : #sources }
Smalltalk class >> categoryOf: aClass [
	"aClass's category, a String ('' when none)."
	^ (self definitionOf: aClass) ifNil: [''] ifNotNil: [:d | d category asString]
]

{ #category : #sources }
Smalltalk class >> categoryOfSelector: aSelector in: aBehavior [
	organizations isNil ifTrue: [^ nil].
	^ (organizations at: aBehavior ifAbsent: [^ nil]) at: aSelector ifAbsent: [nil]
]

{ #category : #sources }
Smalltalk class >> definitionOf: aClass [
	"aClass's ClassDefinition, or nil."
	definitions isNil ifTrue: [^ nil].
	^ definitions at: aClass ifAbsent: [nil]
]

{ #category : #sources }
Smalltalk class >> forgetCategoriesOf: aBehavior [
	organizations isNil ifTrue: [^ nil].
	^ organizations removeKey: aBehavior ifAbsent: [nil]
]

{ #category : #sources }
Smalltalk class >> forgetCategoryOf: aSelector in: aBehavior [
	organizations isNil ifTrue: [^ nil].
	^ (organizations at: aBehavior ifAbsent: [^ nil]) removeKey: aSelector ifAbsent: [nil]
]

{ #category : #sources }
Smalltalk class >> forgetClass: aClass [
	"Every record of aClass and its class side: definition, sources, categories (Smalltalk removeClass:)."
	self forgetDefinitionOf: aClass.
	sources isNil ifFalse: [sources removeKey: aClass ifAbsent: [nil]. sources removeKey: aClass class ifAbsent: [nil]].
	organizations isNil ifFalse: [organizations removeKey: aClass ifAbsent: [nil]. organizations removeKey: aClass class ifAbsent: [nil]].
	undeclared isNil ifFalse: [undeclared removeKey: aClass ifAbsent: [nil]].
	classNames := nil
]

{ #category : #sources }
Smalltalk class >> forgetDefinitionOf: aClass [
	definitions isNil ifTrue: [^ nil].
	^ definitions removeKey: aClass ifAbsent: [nil]
]

{ #category : #sources }
Smalltalk class >> forgetSourceOf: aCompiledMethod [
	sources isNil ifTrue: [^ nil].
	^ (sources at: aCompiledMethod methodClass ifAbsent: [^ nil]) removeKey: aCompiledMethod ifAbsent: [nil]
]

{ #category : #sources }
Smalltalk class >> instanceVariableNamesOf: aClass [
	"Every instance variable name of aClass, inherited first; class-side ones for a metaclass."
	| own d |
	aClass isNil ifTrue: [^ #()].
	aClass isMeta ifTrue: [
		d := self definitionOf: aClass theNonMetaClass.
		own := d isNil ifTrue: [#()] ifFalse: [d classInstVarNames].
		^ (aClass superclass isMeta ifTrue: [self instanceVariableNamesOf: aClass superclass] ifFalse: [#()]) , own].
	d := self definitionOf: aClass.
	own := d isNil ifTrue: [#()] ifFalse: [d instVarNames].
	^ (self instanceVariableNamesOf: aClass superclass) , own
]

{ #category : #sources }
Smalltalk class >> noteCategory: aSymbol of: aSelector in: aBehavior [
	"A method's category, kept per class and side by selector (module 8e)."
	organizations isNil ifTrue: [organizations := IdentityDictionary new].
	(organizations at: aBehavior ifAbsentPut: [IdentityDictionary new]) at: aSelector put: aSymbol
]

{ #category : #sources }
Smalltalk class >> noteDefinition: aClassDefinition of: aClass [
	definitions isNil ifTrue: [definitions := IdentityDictionary new].
	definitions at: aClass put: aClassDefinition
]

{ #category : #sources }
Smalltalk class >> noteSource: aString of: aCompiledMethod [
	"Kept per class: one dictionary of every source would pass the 3071 entries an object of one block can hash (a kernel of 1536 methods filled it, module 8d)."
	sources isNil ifTrue: [sources := IdentityDictionary new].
	(sources at: aCompiledMethod methodClass ifAbsentPut: [IdentityDictionary new]) at: aCompiledMethod put: aString
]

{ #category : #sources }
Smalltalk class >> recordDefinitions: anArray [
	"The image build hands every class definition over, superclasses first (module 8e): the name, the superclass, the instance variables, the class-side instance variables, the category, the format kind and the comment, a line each (the comment last; names separated by blanks)."
	| lf |
	lf := String with: Character lf.
	definitions := IdentityDictionary new.
	anArray do: [:s | | fields start cls |
		fields := OrderedCollection new.
		start := 1.
		6 timesRepeat: [ | j |
			j := s indexOfSubstring: lf startingAt: start.
			fields add: (s copyFrom: start to: j - 1).
			start := j + 1].
		fields add: (s copyFrom: start to: s byteSize).
		cls := self at: (fields at: 1) asSymbol.
		definitions at: cls put: (ClassDefinition
			instVarNames: ((fields at: 3) substrings collect: [:n | n asSymbol])
			classInstVarNames: ((fields at: 4) substrings collect: [:n | n asSymbol])
			category: (fields at: 5) asSymbol
			kind: (fields at: 6) asSymbol
			comment: (fields at: 7))]
]

{ #category : #sources }
Smalltalk class >> recordSources: anArray [
	"The image build hands every method's source over: 'Class[ class]', the selector, the category and the source, a line each (the source last)."
	| lf |
	lf := String with: Character lf.
	anArray do: [:s | | i j k spec sel cls m cat |
		i := s indexOf: Character lf.
		j := s indexOfSubstring: lf startingAt: i + 1.
		k := s indexOfSubstring: lf startingAt: j + 1.
		spec := s copyFrom: 1 to: i - 1.
		sel := (s copyFrom: i + 1 to: j - 1) asSymbol.
		cat := s copyFrom: j + 1 to: k - 1.
		cls := (spec endsWith: ' class')
			ifTrue: [(self at: (spec copyFrom: 1 to: spec byteSize - 6) asSymbol) class]
			ifFalse: [self at: spec asSymbol].
		m := cls compiledMethodAt: sel.
		self noteSource: (s copyFrom: k + 1 to: s byteSize) of: m.
		cat isEmpty ifFalse: [self noteCategory: cat asSymbol of: sel in: cls]]
]

{ #category : #sources }
Smalltalk class >> replaceSources: anAssociationList of: aBehavior [
	"Every source of aBehavior's methods anew, selector -> source (after a redefinition forwarded its methods to their new selves, whose identity hashes the old table does not know)."
	sources isNil ifTrue: [sources := IdentityDictionary new].
	sources removeKey: aBehavior ifAbsent: [nil].
	anAssociationList do: [:a | self noteSource: a value of: (aBehavior compiledMethodAt: a key)]
]

{ #category : #sources }
Smalltalk class >> sourceOf: aCompiledMethod [
	sources isNil ifTrue: [^ nil].
	^ (sources at: aCompiledMethod methodClass ifAbsent: [^ nil]) at: aCompiledMethod ifAbsent: [nil]
]

{ #category : #system }
Smalltalk class >> isReleaseImage [
	"A release image (its header's flag, set by kajo build-image --release or kajo seal): methods cannot be made, installed or removed from Smalltalk, and Compiler evaluate: is refused (module 8d). Nothing in Smalltalk can change it."
	<primitive: 144>
	^ false
]
