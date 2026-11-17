"The system: the classes, their definitions (ClassDefinition, handed over by the image build and kept by the class definition protocol, module 8e), every method's source and category, the kernel's initialization, and the entry point kajo run and kajo test start at (the image names this class in its special objects; each run starts a fresh Process sending run:of:, setup: or test: to it)."
Class {
	#name : #Smalltalk,
	#superclass : #Object,
	#classInstVars : [
		'sources',
		'classNames',
		'definitions',
		'organizations',
		'undeclared',
		'packages',
		'resumes',
		'registryLock',
		'classTypes',
		'changeListener'
	]
}

{ #category : #changes }
Smalltalk class >> changeListener [
	^ changeListener
]

{ #category : #changes }
Smalltalk class >> changeListener: anObjectOrNil [
	"Types 2: the one object told of every change of the image's code (the type checker of a development image), or nil. It answers noteChange:of:in:, beginChanges and endChanges."
	changeListener := anObjectOrNil
]

{ #category : #changes }
Smalltalk class >> changesDuring: aBlock [
	"Types 2: aBlock's changes are one to the listener (a Tonel file loaded is one recheck): it hears of each as it comes, and of the bracket's end."
	| l |
	l := changeListener.
	l isNil ifTrue: [^ aBlock value].
	[l beginChanges] on: Error do: [:e | Transcript showLine: 'change listener: ' , e messageText].
	^ aBlock ensure: [[l endChanges] on: Error do: [:e | Transcript showLine: 'change listener: ' , e messageText]]
]

{ #category : #changes }
Smalltalk class >> noteChange: aKind of: aSelectorOrNil in: aBehavior [
	"Types 2: tell the change listener, when there is one, that aBehavior's code changed. aKind is #method (compiled), #methodRemoved, #signature (added, changed or removed), #class (defined, or redefined: its shape, its types, its methods) or #classRemoved. A plain hook (docs/modules/types-2.md, starting position 3): nil costs one test; an error of the listener is printed and is never the changer's."
	| l |
	l := changeListener.
	l isNil ifTrue: [^ nil].
	[l noteChange: aKind of: aSelectorOrNil in: aBehavior] on: Error do: [:e | Transcript showLine: 'change listener: ' , e messageText]
]

{ #category : #'class variables' }
Smalltalk class >> forgetUndeclared: aSymbol in: aClass [
	^ self registry: [
		undeclared isNil
			ifTrue: [nil]
			ifFalse: [(undeclared at: aClass ifAbsent: [nil]) ifNotNil: [:d | d removeKey: aSymbol ifAbsent: [nil]]]]
]

{ #category : #'class variables' }
Smalltalk class >> noteUndeclared: aBinding in: aClass [
	self registry: [
		undeclared isNil ifTrue: [undeclared := IdentityDictionary new].
		(undeclared at: aClass ifAbsentPut: [IdentityDictionary new]) at: aBinding key put: aBinding]
]

{ #category : #'class variables' }
Smalltalk class >> undeclaredBinding: aSymbol in: aClass [
	"A Binding for a class variable aSymbol of aClass about to be declared: the one removed from aClass earlier, if any (so the methods that hold it work again), else a new one."
	| b |
	b := self registry: [
		undeclared isNil ifFalse: [(undeclared at: aClass ifAbsent: [nil]) ifNotNil: [:d | d at: aSymbol ifAbsent: [nil]]]].
	^ b ifNil: [Binding new key: aSymbol]
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
	"The class named aString, or nil (a table by name, rebuilt when a class is missing from it). The table is read once into a temporary and a rebuild answers its own table, so a Process never reads another one's table while it is being filled."
	| sym names |
	sym := Symbol lookup: aString.
	sym isNil ifTrue: [^ nil].
	names := classNames.
	names isNil ifTrue: [names := self rebuildClassNames].
	^ names at: sym ifAbsent: [self rebuildClassNames at: sym ifAbsent: [nil]]
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
Smalltalk class >> primFreeObsoleteClasses [
	"Primitive 163: in one stop, every removed class with no instance that no object, frame or root names (two full collections) gives its indices back. Answers how many."
	<primitive: 163>
	^ 0
]

{ #category : #classes }
Smalltalk class >> primGarbageCollect [
	<primitive: 11>
	^ nil
]

{ #category : #classes }
Smalltalk class >> rebuildClassNames [
	"A new table of every class by name, filled before it is published (concurrent Processes look classes up: a table published empty and then filled let one of them miss Object, found under load by the tags' tools test). Answers it."
	| names |
	names := IdentityDictionary new.
	self allClasses do: [:c | names at: c name put: c].
	classNames := names.
	^ names
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
Smalltalk class >> evaluate: aString [
	"A doit's value (Compiler evaluate:), for hosts and tests that spawn it."
	^ Compiler evaluate: aString
]

{ #category : #'entry points' }
Smalltalk class >> evaluateStrings: anArray [
	"Each doit's value as a String (itself when it is one, else its printString), for hosts and tests that spawn it."
	^ anArray collect: [:src | | v |
		v := Compiler evaluate: src.
		v isString ifTrue: [v] ifFalse: [v printString]]
]

{ #category : #'entry points' }
Smalltalk class >> garbageCollect [
	"A full collection; then the removed classes nothing names any more are freed (module 9b: their class-table indices become holes a new class takes). Answers how many were freed."
	self primGarbageCollect.
	^ self primFreeObsoleteClasses
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
	"kajo test <image> [--filter pattern] [--tag tag] [--test name]... [--list]: run the matching TestCases, emitting the event stream. Answers the number of failures and errors. Each --test names one test exactly (Class>>selector); with several, a test is run when it is any of them. --list emits the selected tests without running them (gate speed)."
	| filter tag names list i |
	i := 1.
	list := false.
	[i <= arguments size] whileTrue: [
		(arguments at: i) = '--filter' ifTrue: [filter := arguments at: i + 1. i := i + 1].
		(arguments at: i) = '--tag' ifTrue: [tag := arguments at: i + 1. i := i + 1].
		(arguments at: i) = '--test' ifTrue: [
			names ifNil: [names := Set new].
			names add: (arguments at: i + 1).
			i := i + 1].
		(arguments at: i) = '--list' ifTrue: [list := true].
		i := i + 1].
	list ifTrue: [^ TestRunner new listFilter: filter tag: tag tests: names].
	^ TestRunner new runFilter: filter tag: tag tests: names
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
Smalltalk class >> readTonel: aString path: aPath [
	"readTonel: of the file at aPath, relative to its package's directory: the class takes its tag from the path (TonelReader tagOfPath:; a file at the root has none, one two directories down is refused), never from a key in the file (tags as subdirectories)."
	^ TonelLoader load: (TonelReader read: aString) path: aPath
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

{ #category : #'file in' }
Smalltalk class >> tonelTagsOf: anArray [
	"For each path relative to a package's directory, the tag it gives: the tag, '' for none, or 'refused: ' and why (a test compares them with the bootstrap reader's)."
	^ anArray collect: [:p | [(TonelReader tagOfPath: p) ifNil: ['']] on: Error do: [:e | 'refused: ' , e messageText]]
]

{ #category : #'file in' }
Smalltalk class >> typeDescriptionsOf: anArray [
	"For each method source, its types as the Parser keeps them (MethodNode>>typesDescription), or 'refused ' and the CompileError's text (Types 1: a test compares them with the bootstrap compiler's)."
	^ anArray collect: [:s | [(Parser parse: s) typesDescription] on: CompileError do: [:e | 'refused ' , e messageText]]
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
	"Write every class, sealed ones too, as <Name>.class.st into aDirectory, or into its subdirectory <Tag> when the class has a tag (tags as subdirectories), a path under the directory the VM was opened with (kajo run --sources; '' for that directory itself). Answers how many files. Module 8e."
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

{ #category : #packages }
Smalltalk class >> authorOfSelector: aSelector in: aBehavior [
	"The agent that made the method, from its <author: #'agent:<name>'> pragma (the development answers: the mark is part of the method's source; Pragma allNamed: #author: answers every method an agent wrote), else nil."
	| m p |
	m := aBehavior compiledMethodAt: aSelector ifAbsent: [^ nil].
	p := m pragmaAt: #author:.
	p isNil ifTrue: [^ nil].
	^ p arguments first asString
]

{ #category : #packages }
Smalltalk class >> notePackage: aStringOrNil of: aSelector in: aBehavior [
	"A method's package when it is not its class's (an extension, module 9b); nil or the class's package forgets it."
	(aStringOrNil isNil or: [aStringOrNil = (self packageOf: aBehavior theNonMetaClass)]) ifTrue: [
		self registry: [packages isNil ifFalse: [(packages at: aBehavior ifAbsent: [nil]) ifNotNil: [:d | d removeKey: aSelector ifAbsent: [nil]]]].
		^ nil].
	self registry: [
		packages isNil ifTrue: [packages := IdentityDictionary new].
		(packages at: aBehavior ifAbsentPut: [IdentityDictionary new]) at: aSelector put: aStringOrNil asString]
]

{ #category : #packages }
Smalltalk class >> packageNames [
	"Every package a class or a method of the image belongs to, sorted."
	| out |
	out := Set new.
	self allClasses do: [:c | (self packageOf: c) ifNotNil: [:p | out add: p]].
	self registry: [packages isNil ifFalse: [packages do: [:d | d do: [:p | out add: p]]]].
	^ out asArray sort: [:a :b | a <= b]
]

{ #category : #packages }
Smalltalk class >> packageOf: aClass [
	"The class's package (its definition's), or nil."
	^ (self definitionOf: aClass theNonMetaClass) ifNotNil: [:d | d package]
]

{ #category : #packages }
Smalltalk class >> packageOfSelector: aSelector in: aBehavior [
	"The package a method belongs to: its own when it is an extension, else its class's."
	| p |
	p := self registry: [
		packages isNil ifFalse: [(packages at: aBehavior ifAbsent: [nil]) ifNotNil: [:d | d at: aSelector ifAbsent: [nil]]]].
	^ p ifNil: [self packageOf: aBehavior theNonMetaClass]
]

{ #category : #packages }
Smalltalk class >> tagOf: aClass [
	"The class's tag within its package, a Symbol, or nil when it has none (tags as subdirectories: the subdirectory of the package's directory its file is in)."
	^ (self definitionOf: aClass theNonMetaClass) ifNotNil: [:d | d tag]
]

{ #category : #packages }
Smalltalk class >> tagsOf: aPackageOrNil [
	"The tags of the package's classes (of every class when nil), sorted."
	| out |
	out := Set new.
	self allClasses do: [:c |
		(aPackageOrNil isNil or: [(self packageOf: c) = aPackageOrNil]) ifTrue: [(self tagOf: c) ifNotNil: [:t | out add: t asString]]].
	^ out asArray sort: [:a :b | a <= b]
]

{ #category : #packages }
Smalltalk class >> writePackage: aName into: aDirectory [
	"Write the package's files into aDirectory (module 9b): a class file for each of its classes (their methods of the package), in the subdirectory of its tag when it has one, an extension file for each other class with methods of the package, at aDirectory's root. Answers the paths."
	| out |
	out := OrderedCollection new.
	self allClasses do: [:c |
		(self packageOf: c) = aName
			ifTrue: [out add: (TonelWriter write: c package: aName into: aDirectory)]
			ifFalse: [(TonelWriter hasMethodsOf: c package: aName) ifTrue: [out add: (TonelWriter write: c package: aName into: aDirectory)]]].
	^ out asArray
]

{ #category : #packages }
Smalltalk class >> writePackages: anArray [
	"anArray holds package names and directories alternately (module 9c: 'Kernel' 'kernel' 'Tools' 'tools'): each package written into its directory, a path under the opened one. Answers how many files."
	| n |
	n := 0.
	1 to: anArray size by: 2 do: [:i | n := n + (self writePackage: (anArray at: i) into: (anArray at: i + 1)) size].
	^ n
]

{ #category : #primitives }
Smalltalk class >> primAllInstancesOf: aBehaviorOrArray limit: anInteger [
	"Primitive 167 (the discoverability follow-up): an Array of every object in the heap whose class is aBehaviorOrArray (or one of the Array's behaviors), at most anInteger of them, found in one stop after every young object is promoted. nil when refused: a limit outside 0 to 16777215, an argument that is not a behavior, or a heap so full that nothing young could be promoted."
	<primitive: 167>
	^ nil
]

{ #category : #primitives }
Smalltalk class >> primDefineClass: anArray [
	"A class from its specification (ClassBuilder), or a String saying why not (module 8e). Fails in a release image."
	<primitive: 145>
	Smalltalk isReleaseImage ifTrue: [^ InstallForbidden new behavior: nil selector: (anArray at: 1); signal].
	^ self error: 'the VM refused to define a class'
]

{ #category : #primitives }
Smalltalk class >> primInstanceCountOf: aBehaviorOrArray [
	"Primitive 168: how many objects primAllInstancesOf:limit: would find with no limit, allocating nothing; nil when refused."
	<primitive: 168>
	^ nil
]

{ #category : #primitives }
Smalltalk class >> primPointerCountTo: anObject [
	"Primitive 170 (the pointersTo: follow-up): how many objects primPointersTo:limit: would find with no limit, allocating nothing; nil when refused."
	<primitive: 170>
	^ nil
]

{ #category : #primitives }
Smalltalk class >> primPointersTo: anObject limit: anInteger [
	"Primitive 169 (the pointersTo: follow-up): an Array of every object in the heap with a slot holding anObject, at most anInteger of them, found in one stop after every young object is promoted (see Object>>pointersTo). nil when refused: a limit outside 0 to 16777215, or a heap so full that nothing young could be promoted."
	<primitive: 169>
	^ nil
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
	UIEventLoop resumeAfterSnapshot.
	resumes := self resumeCount + 1
]

{ #category : #snapshots }
Smalltalk class >> resumeCount [
	"How many times this image was resumed and its hook ran to the end (a host waits for it before building views the hook would detach)."
	^ resumes ifNil: [0]
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
Smalltalk class >> categoryOfSelector: aSelector in: aBehavior [
	^ self registry: [
		organizations isNil ifFalse: [(organizations at: aBehavior ifAbsent: [nil]) ifNotNil: [:d | d at: aSelector ifAbsent: [nil]]]]
]

{ #category : #sources }
Smalltalk class >> definitionOf: aClass [
	"aClass's ClassDefinition, or nil."
	^ self registry: [definitions isNil ifFalse: [definitions at: aClass ifAbsent: [nil]]]
]

{ #category : #sources }
Smalltalk class >> forgetCategoriesOf: aBehavior [
	^ self registry: [organizations isNil ifFalse: [organizations removeKey: aBehavior ifAbsent: [nil]]]
]

{ #category : #sources }
Smalltalk class >> forgetCategoryOf: aSelector in: aBehavior [
	^ self registry: [
		organizations isNil ifFalse: [(organizations at: aBehavior ifAbsent: [nil]) ifNotNil: [:d | d removeKey: aSelector ifAbsent: [nil]]]]
]

{ #category : #sources }
Smalltalk class >> forgetClass: aClass [
	"Every record of aClass and its class side: definition, sources, categories (Smalltalk removeClass:)."
	self registry: [
		self forgetDefinitionOf: aClass.
		sources isNil ifFalse: [sources removeKey: aClass ifAbsent: [nil]. sources removeKey: aClass class ifAbsent: [nil]].
		organizations isNil ifFalse: [organizations removeKey: aClass ifAbsent: [nil]. organizations removeKey: aClass class ifAbsent: [nil]].
		packages isNil ifFalse: [packages removeKey: aClass ifAbsent: [nil]. packages removeKey: aClass class ifAbsent: [nil]].
		classTypes isNil ifFalse: [classTypes removeKey: aClass ifAbsent: [nil]].
		undeclared isNil ifFalse: [undeclared removeKey: aClass ifAbsent: [nil]]].
	classNames := nil
]

{ #category : #sources }
Smalltalk class >> forgetDefinitionOf: aClass [
	^ self registry: [definitions isNil ifFalse: [definitions removeKey: aClass ifAbsent: [nil]]]
]

{ #category : #sources }
Smalltalk class >> forgetSignatureOf: aSelector in: aBehavior [
	"Forget aBehavior's signature of aSelector (Types 2), and the class's ClassTypes when nothing is left in it; answers the forgotten {text. category. package} or nil."
	| cls |
	cls := aBehavior theNonMetaClass.
	^ self registry: [ | t e |
		t := classTypes isNil ifTrue: [nil] ifFalse: [classTypes at: cls ifAbsent: [nil]].
		e := t isNil ifTrue: [nil] ifFalse: [t removeSignatureAt: aSelector meta: aBehavior isMeta].
		(t notNil and: [t isEmpty]) ifTrue: [classTypes removeKey: cls ifAbsent: [nil]].
		e]
]

{ #category : #sources }
Smalltalk class >> forgetSourceOf: aCompiledMethod [
	^ self registry: [
		sources isNil ifFalse: [(sources at: aCompiledMethod methodClass ifAbsent: [nil]) ifNotNil: [:d | d removeKey: aCompiledMethod ifAbsent: [nil]]]]
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
	self registry: [
		organizations isNil ifTrue: [organizations := IdentityDictionary new].
		(organizations at: aBehavior ifAbsentPut: [IdentityDictionary new]) at: aSelector put: aSymbol]
]

{ #category : #sources }
Smalltalk class >> noteDefinition: aClassDefinition of: aClass [
	self registry: [
		definitions isNil ifTrue: [definitions := IdentityDictionary new].
		definitions at: aClass put: aClassDefinition]
]

{ #category : #sources }
Smalltalk class >> noteSignature: aString category: aCategory package: aPackageOrNil of: aSelector in: aBehavior [
	"Keep a signature without a method of aBehavior (Types 2): the pattern's text in its class's ClassTypes (made when the class has none), with its category and its package (nil or empty: the class's). Nothing checks it here; Behavior>>signature:classified: is the checked way in."
	| cls |
	cls := aBehavior theNonMetaClass.
	self registry: [ | t |
		classTypes isNil ifTrue: [classTypes := IdentityDictionary new].
		t := classTypes at: cls ifAbsent: [nil].
		t isNil ifTrue: [t := ClassTypes new. classTypes at: cls put: t].
		t signature: aString category: aCategory package: aPackageOrNil at: aSelector meta: aBehavior isMeta]
]

{ #category : #sources }
Smalltalk class >> noteSource: aString of: aCompiledMethod [
	"Kept per class: one dictionary of every source would pass the 3071 entries an object of one block can hash (a kernel of 1536 methods filled it, module 8d)."
	self registry: [
		sources isNil ifTrue: [sources := IdentityDictionary new].
		(sources at: aCompiledMethod methodClass ifAbsentPut: [IdentityDictionary new]) at: aCompiledMethod put: aString]
]

{ #category : #sources }
Smalltalk class >> noteTypes: aClassTypesOrNil of: aClass [
	"Keep aClass's types (Types 1; since Types 2 its signatures without a method with them), or forget them for nil or none."
	self registry: [
		(aClassTypesOrNil isNil or: [aClassTypesOrNil isEmpty])
			ifTrue: [classTypes isNil ifFalse: [classTypes removeKey: aClass ifAbsent: [nil]]]
			ifFalse: [
				classTypes isNil ifTrue: [classTypes := IdentityDictionary new].
				classTypes at: aClass put: aClassTypesOrNil]]
]

{ #category : #sources }
Smalltalk class >> recordClassTypes: anArray [
	"The image build hands the class-level types over (Types 1), for the classes that have any: the name, the type parameters (separated by blanks), the superclass type (empty for none), then each typed instance variable's name and its type's text, separated by the record separator (30). A release image's build does not send this."
	| rs |
	rs := Character value: 30.
	anArray do: [:s | | fields types |
		fields := s splitOn: (String with: rs).
		types := ClassTypes new.
		types typeParameters: ((fields at: 2) substrings collect: [:n | n asString]) asArray.
		(fields at: 3) isEmpty ifFalse: [types superclassType: (fields at: 3)].
		4 to: fields size - 1 by: 2 do: [:i | types type: (fields at: i + 1) of: (fields at: i)].
		self noteTypes: types of: (self at: (fields at: 1) asSymbol)]
]

{ #category : #sources }
Smalltalk class >> recordDefinitions: anArray [
	"The image build hands every class definition over, superclasses first (module 8e): the name, the superclass, the instance variables, the class-side instance variables, the tag (empty for none: tags as subdirectories, in the category's place), the format kind, the package (module 9b) and the comment, a line each (the comment last; names separated by blanks)."
	| lf table |
	lf := String with: Character lf.
	table := IdentityDictionary new.
	anArray do: [:s | | fields start cls |
		fields := OrderedCollection new.
		start := 1.
		7 timesRepeat: [ | j |
			j := s indexOfSubstring: lf startingAt: start.
			fields add: (s copyFrom: start to: j - 1).
			start := j + 1].
		fields add: (s copyFrom: start to: s byteSize).
		cls := self at: (fields at: 1) asSymbol.
		table at: cls put: (ClassDefinition
			instVarNames: ((fields at: 3) substrings collect: [:n | n asSymbol])
			classInstVarNames: ((fields at: 4) substrings collect: [:n | n asSymbol])
			package: ((fields at: 7) isEmpty ifTrue: [nil] ifFalse: [fields at: 7])
			tag: ((fields at: 5) isEmpty ifTrue: [nil] ifFalse: [(fields at: 5) asSymbol])
			kind: (fields at: 6) asSymbol
			comment: (fields at: 8))].
	self registry: [definitions := table]
]

{ #category : #sources }
Smalltalk class >> recordSignatures: anArray [
	"The image build hands the signatures without a method over (Types 2, docs/modules/types-2.md): 'Class[ class]', the selector, the category, the package (when it is not the class's, else empty) and the pattern's text, a line each (the text last). A release image's build does not send this."
	| lf |
	lf := String with: Character lf.
	anArray do: [:s | | i j k p spec sel cat pkg meta cls |
		i := s indexOf: Character lf.
		j := s indexOfSubstring: lf startingAt: i + 1.
		k := s indexOfSubstring: lf startingAt: j + 1.
		p := s indexOfSubstring: lf startingAt: k + 1.
		spec := s copyFrom: 1 to: i - 1.
		sel := (s copyFrom: i + 1 to: j - 1) asSymbol.
		cat := s copyFrom: j + 1 to: k - 1.
		pkg := s copyFrom: k + 1 to: p - 1.
		meta := spec endsWith: ' class'.
		cls := self at: (meta ifTrue: [spec copyFrom: 1 to: spec byteSize - 6] ifFalse: [spec]) asSymbol.
		self noteSignature: (s copyFrom: p + 1 to: s byteSize) category: cat package: pkg of: sel in: (meta ifTrue: [cls class] ifFalse: [cls])]
]

{ #category : #sources }
Smalltalk class >> recordSources: anArray [
	"The image build hands every method's source over: 'Class[ class]', the selector, the category, the package (module 9b: when it is not the class's, else empty) and the source, a line each (the source last). An agent's author mark is a pragma in the source (the development answers)."
	| lf |
	lf := String with: Character lf.
	anArray do: [:s | | i j k p spec sel cls m cat pkg |
		i := s indexOf: Character lf.
		j := s indexOfSubstring: lf startingAt: i + 1.
		k := s indexOfSubstring: lf startingAt: j + 1.
		p := s indexOfSubstring: lf startingAt: k + 1.
		spec := s copyFrom: 1 to: i - 1.
		sel := (s copyFrom: i + 1 to: j - 1) asSymbol.
		cat := s copyFrom: j + 1 to: k - 1.
		pkg := s copyFrom: k + 1 to: p - 1.
		cls := (spec endsWith: ' class')
			ifTrue: [(self at: (spec copyFrom: 1 to: spec byteSize - 6) asSymbol) class]
			ifFalse: [self at: spec asSymbol].
		m := cls compiledMethodAt: sel.
		self noteSource: (s copyFrom: p + 1 to: s byteSize) of: m.
		cat isEmpty ifFalse: [self noteCategory: cat asSymbol of: sel in: cls].
		pkg isEmpty ifFalse: [self notePackage: pkg of: sel in: cls]]
]

{ #category : #sources }
Smalltalk class >> registry: aBlock [
	"aBlock with the registries (sources, categories, packages, definitions, undeclared Bindings, the pragma index) to itself (the review fixes, item 10: protocol requests run in Processes of their own, in parallel, and wrote them unsynchronized). A Mutex, so the same Process may enter again; made at the image build's first note (one Process), kept in the image."
	registryLock isNil ifTrue: [registryLock := Mutex new].
	^ registryLock critical: aBlock
]

{ #category : #sources }
Smalltalk class >> replaceSources: anAssociationList of: aBehavior [
	"Every source of aBehavior's methods anew, selector -> source (after a redefinition forwarded its methods to their new selves, whose identity hashes the old table does not know)."
	| d |
	d := IdentityDictionary new.
	anAssociationList do: [:a | d at: (aBehavior compiledMethodAt: a key) put: a value].
	self registry: [
		sources isNil ifTrue: [sources := IdentityDictionary new].
		sources at: aBehavior put: d]
]

{ #category : #sources }
Smalltalk class >> signatureOf: aSelector in: aBehavior [
	"aBehavior's signature without a method of aSelector (Types 2): {the pattern's text. its category. its package or nil}, or nil."
	^ (self typesOf: aBehavior theNonMetaClass) ifNotNil: [:t | t signatureAt: aSelector meta: aBehavior isMeta]
]

{ #category : #sources }
Smalltalk class >> sourceOf: aCompiledMethod [
	^ self registry: [
		sources isNil ifFalse: [(sources at: aCompiledMethod methodClass ifAbsent: [nil]) ifNotNil: [:d | d at: aCompiledMethod ifAbsent: [nil]]]]
]

{ #category : #sources }
Smalltalk class >> typesOf: aClass [
	"aClass's ClassTypes, or nil when its definition writes no type (Types 1)."
	^ self registry: [classTypes isNil ifFalse: [classTypes at: aClass ifAbsent: [nil]]]
]

{ #category : #system }
Smalltalk class >> isReleaseImage [
	"A release image (its header's flag, set by kajo build-image --release or kajo seal): methods cannot be made, installed or removed from Smalltalk, and Compiler evaluate: is refused (module 8d). Nothing in Smalltalk can change it."
	<primitive: 144>
	^ false
]
