"Writes like a WriteStream and reads back what was written (positions as in WriteStream)."
Class {
	#name : #ReadWriteStream,
	#superclass : #WriteStream
}

{ #category : #accessing }
ReadWriteStream >> contents [
	isText ifFalse: [^ collection copyFrom: 1 to: self readLimit].
	^ (collection copyFrom: 1 to: self readLimit) asStringValidating
]

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
