"A temporary or argument of a method, a real block or an inlined block. kind: #argument #temporary #hidden #inlinedArgument."
Class {
	#name : #TempVariable,
	#superclass : #Object,
	#instVars : [
		'name',
		'kind',
		'scope',
		'seq',
		'captured',
		'written',
		'index',
		'vectorSlot'
	]
}

{ #category : #accessing }
TempVariable >> beCaptured [
	captured := true
]

{ #category : #accessing }
TempVariable >> beWritten [
	written := true
]

{ #category : #accessing }
TempVariable >> inVector [
	^ captured and: [written]
]

{ #category : #accessing }
TempVariable >> index [
	^ index
]

{ #category : #accessing }
TempVariable >> index: n [
	index := n
]

{ #category : #accessing }
TempVariable >> isCaptured [
	^ captured
]

{ #category : #accessing }
TempVariable >> kind [
	^ kind
]

{ #category : #accessing }
TempVariable >> name [
	^ name
]

{ #category : #accessing }
TempVariable >> owner [
	"The scope whose temp vector holds the variable when it is in one."
	^ scope owner
]

{ #category : #accessing }
TempVariable >> real [
	^ scope real
]

{ #category : #accessing }
TempVariable >> scope [
	^ scope
]

{ #category : #accessing }
TempVariable >> seq [
	^ seq
]

{ #category : #accessing }
TempVariable >> setName: aString kind: aSymbol scope: aScope seq: n [
	name := aString.
	kind := aSymbol.
	scope := aScope.
	seq := n.
	captured := false.
	written := false.
	index := -1.
	vectorSlot := -1
]

{ #category : #accessing }
TempVariable >> vectorSlot [
	^ vectorSlot
]

{ #category : #accessing }
TempVariable >> vectorSlot: n [
	vectorSlot := n
]

{ #category : #accessing }
TempVariable class >> name: aString kind: aSymbol scope: aScope seq: n [
	^ self new setName: aString kind: aSymbol scope: aScope seq: n
]
