"A native event the shell posted (module 9a's event queue): its kind, the handle of the view it is for (0: none), its value, and the time it happened in microseconds on the clock of Smalltalk microsecondClock."
Class {
	#name : #UIEvent,
	#superclass : #Object,
	#instVars : [
		'kind',
		'target',
		'value',
		'time'
	],
	#category : #'Kernel-UI'
}

{ #category : #accessing }
UIEvent >> age [
	"Microseconds since the event happened."
	^ Smalltalk microsecondClock - time
]

{ #category : #accessing }
UIEvent >> kind [
	^ kind
]

{ #category : #accessing }
UIEvent >> setKind: aSymbol target: aHandle value: anObject time: microseconds [
	kind := aSymbol.
	target := aHandle.
	value := anObject.
	time := microseconds
]

{ #category : #accessing }
UIEvent >> target [
	^ target
]

{ #category : #accessing }
UIEvent >> time [
	^ time
]

{ #category : #accessing }
UIEvent >> value [
	^ value
]

{ #category : #printing }
UIEvent >> printOn: aStream [
	aStream nextPutAll: 'a UIEvent('; print: kind; space; print: target; space; print: value; nextPut: $)
]

{ #category : #accessing }
UIEvent class >> fromArray: anArray [
	"What primitive 154 answers: {kind number. target. value. microseconds}."
	| n |
	n := anArray at: 1.
	^ self
		kind: ((n between: 1 and: self kinds size) ifTrue: [self kinds at: n] ifFalse: [#unknown])
		target: (anArray at: 2)
		value: (anArray at: 3)
		time: (anArray at: 4)
]

{ #category : #accessing }
UIEvent class >> kind: aSymbol target: aHandle value: anObject time: microseconds [
	^ self basicNew setKind: aSymbol target: aHandle value: anObject time: microseconds
]

{ #category : #accessing }
UIEvent class >> kinds [
	"By the shell's number (ShellEventKind; module 9c added key to textChanged)."
	^ #(#click #valueChanged #close #frame #synthetic #text #key #selectionChanged #doubleClick #expand #menu #line #lost #timer #textChanged #linePart #targets)
]
