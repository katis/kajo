"The text of one JSON value in pieces (module 9c, when no object was larger than one heap block; module 10 keeps the pieces for the transport, though one String may now hold a line): a reply or an event longer than that is written by Json class>>writePieces: as ByteArrays of at most 16 KiB, which the host's transport joins into its one line, and a line the client's transport received past 16 MiB - 1 is handed to the image in Strings of at most that (large bytes, part 3: shorter lines arrive as one String, measured cheaper), which Json class>>read: reads through this: byteAt:, byteSize and copyFrom:to: across the pieces, as the reader asks a String."
Class {
	#name : #JsonText,
	#superclass : #Object,
	#instVars : [
		'pieces',
		'starts',
		'size',
		'last'
	],
	#category : #'Kernel-Development'
}

{ #category : #accessing }
JsonText >> byteAt: index [
	"The byte at index; the piece found from the last one looked at (the reader goes forward)."
	| i |
	i := last.
	(index >= (starts at: i) and: [index < ((starts at: i) + (pieces at: i) byteSize)]) ifFalse: [
		i := 1.
		[i < pieces size and: [index >= (starts at: i + 1)]] whileTrue: [i := i + 1].
		last := i].
	^ (pieces at: i) byteAt: index - (starts at: i) + 1
]

{ #category : #accessing }
JsonText >> byteSize [
	^ size
]

{ #category : #accessing }
JsonText >> copyFrom: start to: stop [
	"Bytes start to stop as a String (the reader asks for short spans: a literal, a number)."
	| b |
	stop < start ifTrue: [^ ''].
	b := ByteArray new: stop - start + 1.
	start to: stop do: [:k | b at: k - start + 1 put: (self byteAt: k)].
	^ b asString
]

{ #category : #accessing }
JsonText >> setPieces: anArray [
	pieces := anArray.
	starts := Array new: anArray size.
	size := 0.
	anArray doWithIndex: [:p :i | starts at: i put: size + 1. size := size + p byteSize].
	last := 1
]

{ #category : #'instance creation' }
JsonText class >> pieces: anArray [
	"anArray of Strings (or ByteArrays), the text in order."
	^ self new setPieces: anArray
]
