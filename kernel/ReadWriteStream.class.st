"Writes like a WriteStream and reads back what was written (positions as in WriteStream)."
Class {
	#name : #ReadWriteStream,
	#superclass : #WriteStream,
	#category : #'Kernel-Streams'
}

{ #category : #accessing }
ReadWriteStream >> next [
	| c |
	self atEnd ifTrue: [^ nil].
	isText ifTrue: [
		c := collection utf8ScalarAt: position + 1.
		position := position + c utf8Size.
		^ c].
	position := position + 1.
	^ collection at: position
]

{ #category : #accessing }
ReadWriteStream >> contents [
	| out |
	isText ifFalse: [^ collection copyFrom: 1 to: readLimit].
	out := ByteArray new: readLimit.
	1 to: readLimit do: [:i | out at: i put: (collection at: i)].
	^ out asStringValidating
]
