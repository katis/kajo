"The system: the classes, the class definitions the image build recorded (kernelDefinitions), the kernel's initialization, and the entry point kajo run and kajo test start at (the image names this class in its special objects; each run starts a fresh Process sending run:of:, setup: or test: to it)."
Class {
	#name : #Smalltalk,
	#superclass : #Object,
	#classInstVars : [
		'sources',
		'classNames'
	],
	#category : #'Kernel-System'
}

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
	^ self allBehaviors reject: [:c | c isMeta]
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
Smalltalk class >> at: aSymbol [
	^ self at: aSymbol ifAbsent: [KeyNotFound new key: aSymbol; signal: 'no class ' , aSymbol]
]

{ #category : #classes }
Smalltalk class >> at: aSymbol ifAbsent: aBlock [
	^ (self classNamed: aSymbol) ifNil: [aBlock value]
]

{ #category : #classes }
Smalltalk class >> includesKey: aSymbol [
	^ (self at: aSymbol ifAbsent: [nil]) notNil
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
Smalltalk class >> rebuildClassNames [
	classNames := IdentityDictionary new.
	self allClasses do: [:c | classNames at: c name put: c]
]

{ #category : #sources }
Smalltalk class >> recordSources: anArray [
	"The image build hands every method's source over: 'Class[ class]', the selector and the source, a line each."
	anArray do: [:s | | i j spec sel cls m |
		i := s indexOf: Character lf.
		j := s indexOfSubstring: (String with: Character lf) startingAt: i + 1.
		spec := s copyFrom: 1 to: i - 1.
		sel := (s copyFrom: i + 1 to: j - 1) asSymbol.
		cls := (spec endsWith: ' class')
			ifTrue: [(self at: (spec copyFrom: 1 to: spec byteSize - 6) asSymbol) class]
			ifFalse: [self at: spec asSymbol].
		m := cls compiledMethodAt: sel.
		self noteSource: (s copyFrom: j + 1 to: s byteSize) of: m]
]

{ #category : #sources }
Smalltalk class >> sourceOf: aCompiledMethod [
	sources isNil ifTrue: [^ nil].
	^ (sources at: aCompiledMethod methodClass ifAbsent: [^ nil]) at: aCompiledMethod ifAbsent: [nil]
]

{ #category : #sources }
Smalltalk class >> noteSource: aString of: aCompiledMethod [
	"Kept per class: one dictionary of every source would pass the 3071 entries an object of one block can hash (a kernel of 1536 methods filled it, module 8d)."
	sources isNil ifTrue: [sources := IdentityDictionary new].
	(sources at: aCompiledMethod methodClass ifAbsentPut: [IdentityDictionary new]) at: aCompiledMethod put: aString
]

{ #category : #sources }
Smalltalk class >> definitionOf: aClass [
	^ self kernelDefinitions detect: [:d | d first == aClass name] ifNone: [nil]
]

{ #category : #sources }
Smalltalk class >> instanceVariableNamesOf: aClass [
	"Every instance variable name of aClass, inherited first; class-side ones for a metaclass."
	| own d |
	aClass isNil ifTrue: [^ #()].
	aClass isMeta ifTrue: [
		d := self definitionOf: aClass theNonMetaClass.
		own := d isNil ifTrue: [#()] ifFalse: [d at: 4].
		^ (aClass superclass isMeta ifTrue: [self instanceVariableNamesOf: aClass superclass] ifFalse: [#()]) , own].
	d := self definitionOf: aClass.
	own := d isNil ifTrue: [#()] ifFalse: [d at: 3].
	^ (self instanceVariableNamesOf: aClass superclass) , own
]

{ #category : #sources }
Smalltalk class >> categoryOf: aClass [
	^ (self definitionOf: aClass) ifNil: [''] ifNotNil: [:d | d at: 5]
]

{ #category : #initialization }
Smalltalk class >> initializeKernel [
	"Run by the image build before the image is saved: each class's own class-side initialize, superclasses first, then the pragma index."
	self kernelDefinitions do: [:d | | c |
		c := self at: d first.
		(c class includesSelector: #initialize) ifTrue: [c initialize]].
	Pragma rebuildIndex.
	Ephemeron forgetProcess
]

{ #category : #'entry points' }
Smalltalk class >> setup: workers [
	(nil respondsTo: #setup:) ifTrue: [nil perform: #setup: with: workers].
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

{ #category : #system }
Smalltalk class >> isReleaseImage [
	"A release image (its header's flag, set by kajo build-image --release or kajo seal): methods cannot be made, installed or removed from Smalltalk, and Compiler evaluate: is refused (module 8d). Nothing in Smalltalk can change it."
	<primitive: 144>
	^ false
]

{ #category : #sources }
Smalltalk class >> forgetSourceOf: aCompiledMethod [
	sources isNil ifTrue: [^ nil].
	^ (sources at: aCompiledMethod methodClass ifAbsent: [^ nil]) removeKey: aCompiledMethod ifAbsent: [nil]
]

{ #category : #'entry points' }
Smalltalk class >> microsecondClock [
	<primitive: 141>
	^ 0
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

{ #category : #'entry points' }
Smalltalk class >> garbageCollect [
	<primitive: 11>
	^ nil
]
