"Writes into a collection, growing it by copying. On a String it writes UTF-8 into a ByteArray buffer and contents answers a new String: a String cannot be its own buffer, since it has no at:put:. readLimit, the end of what was written, is brought up to position where it is read (readLimit), not on every put."
Class {
	#name : #WriteStream,
	#superclass : #PositionableStream,
	#typeParameters : [
		'C'
	]
}

{ #category : #accessing }
WriteStream >> << anObject <Object> ^<Self> [
	anObject isString ifTrue: [self nextPutAll: anObject] ifFalse: [anObject displayOn: self]
]

{ #category : #accessing }
WriteStream >> atEnd ^<Boolean> [
	^ position >= self readLimit
]

{ #category : #accessing }
WriteStream >> contents ^<C> [
	isText ifFalse: [^ collection copyFrom: 1 to: position].
	^ (collection copyFrom: 1 to: position) asStringValidating
]

{ #category : #accessing }
WriteStream >> cr ^<Self> [
	self nextPut: Character cr
]

{ #category : #accessing }
WriteStream >> display: anObject <Object> ^<Self> [
	anObject displayOn: self
]

{ #category : #accessing }
WriteStream >> grow ^<Self> [
	self growTo: collection size + 1
]

{ #category : #accessing }
WriteStream >> growTo: n <Integer> ^<Self> [
	"Room for at least n elements (bytes on a String): the size doubled until it fits, at least 16, the elements copied in one replaceFrom:to:with:startingAt: (primitive 38 for an Array or a ByteArray)."
	| size bigger |
	size := collection size * 2 max: 16.
	[size < n] whileTrue: [size := size * 2].
	bigger := collection species new: size.
	bigger replaceFrom: 1 to: collection size with: collection startingAt: 1.
	collection := bigger
]

{ #category : #accessing }
WriteStream >> isEmpty ^<Boolean> [
	^ position = 0
]

{ #category : #accessing }
WriteStream >> lf ^<Self> [
	self nextPut: Character lf
]

{ #category : #accessing }
WriteStream >> newLine ^<Self> [
	self nextPut: Character lf
]

{ #category : #accessing }
WriteStream >> next: n <Integer> put: anObject <Object> ^<Object> [
	n timesRepeat: [self nextPut: anObject]
]

{ #category : #accessing }
WriteStream >> nextPut: anObject <Object> ^<Object> [
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
WriteStream >> nextPutAll: aCollection <SequenceableCollection> ^<SequenceableCollection> [
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
WriteStream >> nextPutGrowing: anObject <Object> ^<Object> [
	"nextPut: on a String stream when the encoding primitive failed: anObject is no Character, or it did not fit."
	| n |
	anObject isCharacter ifFalse: [^ self error: 'a String stream takes Characters'].
	[(n := collection encode: anObject at: position + 1) isNil] whileTrue: [self grow].
	position := position + n.
	^ anObject
]

{ #category : #accessing }
WriteStream >> position: anInteger <Integer> ^<Self> [
	(anInteger between: 0 and: self readLimit) ifFalse: [^ self error: 'position out of range'].
	position := anInteger
]

{ #category : #accessing }
WriteStream >> print: anObject <Object> ^<Self> [
	anObject printOn: self
]

{ #category : #accessing }
WriteStream >> readLimit ^<Integer> [
	"The end of what was written: the furthest position reached, brought up to date here rather than on every put. Every method that reads readLimit or moves position back reads it through this."
	position > readLimit ifTrue: [readLimit := position].
	^ readLimit
]

{ #category : #accessing }
WriteStream >> reset ^<Self> [
	self readLimit.
	position := 0
]

{ #category : #accessing }
WriteStream >> resetContents ^<Self> [
	position := 0.
	readLimit := 0
]

{ #category : #accessing }
WriteStream >> setOn: aCollection <C> ^<Self> [
	isText := aCollection isString.
	isText
		ifTrue: [collection := ByteArray new: 32]
		ifFalse: [collection := aCollection].
	position := 0.
	readLimit := 0
]

{ #category : #accessing }
WriteStream >> skip: n <Integer> ^<Self> [
	self readLimit.
	^ super skip: n
]

{ #category : #accessing }
WriteStream >> space ^<Self> [
	self nextPut: Character space
]

{ #category : #accessing }
WriteStream >> tab ^<Self> [
	self nextPut: Character tab
]
