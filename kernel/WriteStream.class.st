"Writes into a collection, growing it by copying. On a String it writes UTF-8 into a ByteArray buffer and contents answers a new String: a String cannot be its own buffer, since it has no at:put:. readLimit, the end of what was written, is brought up to position where it is read (readLimit), not on every put."
Class {
	#name : #WriteStream,
	#superclass : #PositionableStream,
	#category : #'Kernel-Streams'
}

{ #category : #accessing }
WriteStream >> << anObject [
	anObject isString ifTrue: [self nextPutAll: anObject] ifFalse: [anObject displayOn: self]
]

{ #category : #accessing }
WriteStream >> atEnd [
	^ position >= self readLimit
]

{ #category : #accessing }
WriteStream >> contents [
	isText ifFalse: [^ collection copyFrom: 1 to: position].
	^ (collection copyFrom: 1 to: position) asStringValidating
]

{ #category : #accessing }
WriteStream >> cr [
	self nextPut: Character cr
]

{ #category : #accessing }
WriteStream >> display: anObject [
	anObject displayOn: self
]

{ #category : #accessing }
WriteStream >> grow [
	self growTo: collection size + 1
]

{ #category : #accessing }
WriteStream >> growTo: n [
	"Room for at least n elements (bytes on a String): the size doubled until it fits, at least 16, the elements copied in one replaceFrom:to:with:startingAt: (primitive 38 for an Array or a ByteArray)."
	| size bigger |
	size := collection size * 2 max: 16.
	[size < n] whileTrue: [size := size * 2].
	bigger := collection species new: size.
	bigger replaceFrom: 1 to: collection size with: collection startingAt: 1.
	collection := bigger
]

{ #category : #accessing }
WriteStream >> isEmpty [
	^ position = 0
]

{ #category : #accessing }
WriteStream >> lf [
	self nextPut: Character lf
]

{ #category : #accessing }
WriteStream >> newLine [
	self nextPut: Character lf
]

{ #category : #accessing }
WriteStream >> next: n put: anObject [
	n timesRepeat: [self nextPut: anObject]
]

{ #category : #accessing }
WriteStream >> nextPut: anObject [
	"On a String one send per Character, the encoding primitive's (128), which fails when the Character does not fit or anObject is no Character; nextPutGrowing: sorts that out."
	| n |
	isText ifTrue: [
		(n := collection encode: anObject at: position + 1) isNil ifTrue: [^ self nextPutGrowing: anObject].
		position := position + n.
		^ anObject].
	position >= collection size ifTrue: [self grow].
	position := position + 1.
	^ collection at: position put: anObject
]

{ #category : #accessing }
WriteStream >> nextPutAll: aCollection [
	"A String on a String stream, or an Array or a ByteArray on a stream over the same class, is copied in one replaceFrom:to:with:startingAt: (primitive 38); anything else element by element."
	| n |
	(isText
		ifTrue: [aCollection isString]
		ifFalse: [aCollection class == collection class and: [collection isArray or: [collection class == ByteArray]]])
			ifFalse: [
				aCollection do: [:e | self nextPut: e].
				^ aCollection].
	n := isText ifTrue: [aCollection byteSize] ifFalse: [aCollection size].
	position + n > collection size ifTrue: [self growTo: position + n].
	collection replaceFrom: position + 1 to: position + n with: aCollection startingAt: 1.
	position := position + n.
	^ aCollection
]

{ #category : #accessing }
WriteStream >> nextPutGrowing: anObject [
	"nextPut: on a String stream when the encoding primitive failed: anObject is no Character, or it did not fit."
	| n |
	anObject isCharacter ifFalse: [^ self error: 'a String stream takes Characters'].
	[(n := collection encode: anObject at: position + 1) isNil] whileTrue: [self grow].
	position := position + n.
	^ anObject
]

{ #category : #accessing }
WriteStream >> position: anInteger [
	(anInteger between: 0 and: self readLimit) ifFalse: [^ self error: 'position out of range'].
	position := anInteger
]

{ #category : #accessing }
WriteStream >> print: anObject [
	anObject printOn: self
]

{ #category : #accessing }
WriteStream >> readLimit [
	"The end of what was written: the furthest position reached, brought up to date here rather than on every put. Every method that reads readLimit or moves position back reads it through this."
	position > readLimit ifTrue: [readLimit := position].
	^ readLimit
]

{ #category : #accessing }
WriteStream >> reset [
	self readLimit.
	position := 0
]

{ #category : #accessing }
WriteStream >> resetContents [
	position := 0.
	readLimit := 0
]

{ #category : #accessing }
WriteStream >> setOn: aCollection [
	isText := aCollection isString.
	isText
		ifTrue: [collection := ByteArray new: 32]
		ifFalse: [collection := aCollection].
	position := 0.
	readLimit := 0
]

{ #category : #accessing }
WriteStream >> skip: n [
	self readLimit.
	^ super skip: n
]

{ #category : #accessing }
WriteStream >> space [
	self nextPut: Character space
]

{ #category : #accessing }
WriteStream >> tab [
	self nextPut: Character tab
]
