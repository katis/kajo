"A method's pragma (<slow>, <primitive: 60> excepted: the compiler consumes that one). Pragma allNamed: answers every installed method's pragma with a selector from an index kept by installation; allNamed:in: scans one class."
Class {
	#name : #Pragma,
	#superclass : #Object,
	#instVars : [
		'selector',
		'arguments',
		'method'
	],
	#category : #'Kernel-Methods'
}

{ #category : #accessing }
Pragma class >> consumesPragmas [
	<consumesPragmas: #(#mainThread #devProtocol)>
	"Main-thread affinity (ADR 0004) and the development protocol: declared here so the compiler does not warn; nothing reads them in 8b."
	^ #(#mainThread #devProtocol)
]

{ #category : #accessing }
Pragma class >> rebuildIndex [
	PragmaIndex table: IdentityDictionary new.
	Smalltalk allBehaviors do: [:c | c methodsDo: [:m | self noteInstalled: m]]
]

{ #category : #accessing }
Pragma class >> index [
	PragmaIndex table isNil ifTrue: [self rebuildIndex].
	^ PragmaIndex table
]

{ #category : #accessing }
Pragma class >> noteInstalled: aMethod [
	aMethod isNil ifTrue: [^ self].
	aMethod pragmas do: [:p | (self index at: p selector ifAbsentPut: [OrderedCollection new]) add: p]
]

{ #category : #accessing }
Pragma class >> noteRemoved: aMethod [
	aMethod isNil ifTrue: [^ self].
	aMethod pragmas do: [:p |
		(self index at: p selector ifAbsent: [nil]) ifNotNil: [:list | list remove: p ifAbsent: [nil]]]
]

{ #category : #accessing }
Pragma class >> allNamed: aSymbol [
	^ (self index at: aSymbol ifAbsent: [#()]) asArray
]

{ #category : #accessing }
Pragma class >> allNamed: aSymbol in: aClass [
	| out |
	out := OrderedCollection new.
	aClass methodsDo: [:m | m pragmas do: [:p | p selector == aSymbol ifTrue: [out add: p]]].
	^ out asArray
]

{ #category : #accessing }
Pragma >> selector [
	^ selector
]

{ #category : #accessing }
Pragma >> keyword [
	^ selector
]

{ #category : #accessing }
Pragma >> arguments [
	^ arguments
]

{ #category : #accessing }
Pragma >> method [
	^ method
]

{ #category : #accessing }
Pragma >> numArgs [
	^ arguments size
]

{ #category : #accessing }
Pragma >> argumentAt: i [
	^ arguments at: i
]

{ #category : #accessing }
Pragma >> methodClass [
	^ method methodClass
]

{ #category : #accessing }
Pragma >> printOn: aStream [
	aStream nextPut: $<.
	arguments isEmpty
		ifTrue: [aStream nextPutAll: selector]
		ifFalse: [selector keywords with: arguments do: [:k :a | aStream nextPutAll: k; space; print: a; space]].
	aStream nextPut: $>
]
