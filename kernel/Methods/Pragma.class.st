"A method's pragma (<slow>, <primitive: 60> excepted: the compiler consumes that one). Pragma allNamed: answers every installed method's pragma with a selector from an index kept by installation; allNamed:in: scans one class."
Class {
	#name : #Pragma,
	#superclass : #Object,
	#instVars : [
		'selector',
		'arguments',
		'method'
	]
}

{ #category : #accessing }
Pragma >> argumentAt: i [
	^ arguments at: i
]

{ #category : #accessing }
Pragma >> arguments [
	^ arguments
]

{ #category : #accessing }
Pragma >> keyword [
	^ selector
]

{ #category : #accessing }
Pragma >> method [
	^ method
]

{ #category : #accessing }
Pragma >> methodClass [
	^ method methodClass
]

{ #category : #accessing }
Pragma >> numArgs [
	^ arguments size
]

{ #category : #accessing }
Pragma >> printOn: aStream [
	aStream nextPut: $<.
	arguments isEmpty
		ifTrue: [aStream nextPutAll: selector]
		ifFalse: [selector keywords with: arguments do: [:k :a | aStream nextPutAll: k; space; print: a; space]].
	aStream nextPut: $>
]

{ #category : #accessing }
Pragma >> selector [
	^ selector
]

{ #category : #accessing }
Pragma >> setSelector: aSymbol arguments: anArray [
	selector := aSymbol.
	arguments := anArray
]

{ #category : #accessing }
Pragma class >> allNamed: aSymbol [
	^ Smalltalk registry: [(self index at: aSymbol ifAbsent: [#()]) asArray]
]

{ #category : #accessing }
Pragma class >> allNamed: aSymbol in: aClass [
	| out |
	out := OrderedCollection new.
	aClass methodsDo: [:m | m pragmas do: [:p | p selector == aSymbol ifTrue: [out add: p]]].
	^ out asArray
]

{ #category : #accessing }
Pragma class >> consumesPragmas [
	<consumesPragmas: #(#mainThread #devProtocol #debuggable #author:)>
	"Main-thread affinity (ADR 0004), the development protocol's requests (module 9b: DevProtocol reads them), the requests whose errors stop for the debugger, and the author mark of a method an agent's session made (the development answers: Smalltalk authorOfSelector:in:): declared here so the compiler does not warn."
	^ #(#mainThread #devProtocol #debuggable #author:)
]

{ #category : #accessing }
Pragma class >> index [
	"The index, built when there is none (under Smalltalk registry:, which its readers and writers hold)."
	^ PragmaIndex table ifNil: [self rebuildIndex]
]

{ #category : #accessing }
Pragma class >> note: aMethod in: anIndex [
	aMethod pragmas do: [:p | (anIndex at: p selector ifAbsentPut: [OrderedCollection new]) add: p]
]

{ #category : #accessing }
Pragma class >> noteInstalled: aMethod [
	aMethod isNil ifTrue: [^ self].
	Smalltalk registry: [self note: aMethod in: self index]
]

{ #category : #accessing }
Pragma class >> noteRemoved: aMethod [
	aMethod isNil ifTrue: [^ self].
	Smalltalk registry: [
		aMethod pragmas do: [:p |
			(self index at: p selector ifAbsent: [nil]) ifNotNil: [:list | list remove: p ifAbsent: [nil]]]]
]

{ #category : #accessing }
Pragma class >> rebuildIndex [
	"A new index filled before it is published (the review fixes, item 10: it was published empty and then filled, the shape 211a6ee fixed for class names); built and published under Smalltalk registry:, so no installation in between is lost. Answers it."
	^ Smalltalk registry: [ | d |
		d := IdentityDictionary new.
		Smalltalk allBehaviors do: [:c | c methodsDo: [:m | self note: m in: d]].
		PragmaIndex table: d.
		d]
]

{ #category : #'instance creation' }
Pragma class >> selector: aSymbol arguments: anArray [
	"A pragma the compiler made (no method yet): the make-method primitive makes a read-only one for the method it makes (module 8d)."
	^ self new setSelector: aSymbol arguments: anArray
]
