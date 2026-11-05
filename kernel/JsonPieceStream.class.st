"Where Json class>>writePieces: writes (module 9c): bytes into ByteArrays of 16 KiB, a new one when the last is full, for the transport, which writes a long line in pieces (module 10 lets Json class>>write: answer one ByteArray of any size)."
Class {
	#name : #JsonPieceStream,
	#superclass : #Object,
	#instVars : [
		'done',
		'current',
		'position'
	],
	#category : #'Kernel-Development'
}

{ #category : #writing }
JsonPieceStream >> initialize [
	done := OrderedCollection new.
	current := ByteArray new: 16384.
	position := 0
]

{ #category : #writing }
JsonPieceStream >> nextPut: aByte [
	position = 16384 ifTrue: [
		done add: current.
		current := ByteArray new: 16384.
		position := 0].
	position := position + 1.
	^ current at: position put: aByte
]

{ #category : #writing }
JsonPieceStream >> pieces [
	"The ByteArrays written, the last cut to what it holds."
	^ (done copyWith: (current copyFrom: 1 to: position)) asArray
]
