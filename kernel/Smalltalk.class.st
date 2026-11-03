"The system: the classes, the class definitions the image build recorded (kernelDefinitions), the kernel's initialization, and the entry point kajo run and kajo test start at (the image names this class in its special objects; each run starts a fresh Process sending run:of:, setup: or test: to it)."
Class {
	#name : #Smalltalk,
	#superclass : #Object,
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
	^ self allClasses detect: [:c | c name == aSymbol] ifNone: aBlock
]

{ #category : #classes }
Smalltalk class >> includesKey: aSymbol [
	^ (self at: aSymbol ifAbsent: [nil]) notNil
]

{ #category : #classes }
Smalltalk class >> definitionOf: aClass [
	^ self kernelDefinitions detect: [:d | d first == aClass name] ifNone: [nil]
]

{ #category : #classes }
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

{ #category : #classes }
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
Smalltalk class >> microsecondClock [
	<primitive: 141>
	^ 0
]

{ #category : #'entry points' }
Smalltalk class >> garbageCollect [
	<primitive: 11>
	^ nil
]
