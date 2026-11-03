"Writes into a collection, growing it by copying. On a String it writes UTF-8 into a ByteArray buffer and contents answers a new String: a String cannot be its own buffer, since it has no at:put:."
Class {
	#name : #WriteStream,
	#superclass : #PositionableStream,
	#category : #'Kernel-Streams'
}

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
WriteStream >> nextPut: anObject [
	| n |
	isText ifTrue: [
		anObject isCharacter ifFalse: [^ self error: 'a String stream takes Characters'].
		[(n := collection encode: anObject at: position + 1) isNil] whileTrue: [self grow].
		position := position + n.
		readLimit := readLimit max: position.
		^ anObject].
	position >= collection size ifTrue: [self grow].
	position := position + 1.
	readLimit := readLimit max: position.
	^ collection at: position put: anObject
]

{ #category : #accessing }
WriteStream >> nextPutAll: aCollection [
	| n |
	(isText and: [aCollection isString]) ifTrue: [
		n := aCollection byteSize.
		[position + n > collection size] whileTrue: [self grow].
		1 to: n do: [:i | collection at: position + i put: (aCollection byteAt: i)].
		position := position + n.
		readLimit := readLimit max: position.
		^ aCollection].
	aCollection do: [:e | self nextPut: e].
	^ aCollection
]

{ #category : #accessing }
WriteStream >> grow [
	| bigger |
	bigger := collection species new: (collection size * 2 max: 16).
	1 to: collection size do: [:i | bigger at: i put: (collection at: i)].
	collection := bigger
]

{ #category : #accessing }
WriteStream >> contents [
	| out |
	isText ifFalse: [^ collection copyFrom: 1 to: position].
	out := ByteArray new: position.
	1 to: position do: [:i | out at: i put: (collection at: i)].
	^ out asStringValidating
]

{ #category : #accessing }
WriteStream >> atEnd [
	^ position >= readLimit
]

{ #category : #accessing }
WriteStream >> reset [
	position := 0
]

{ #category : #accessing }
WriteStream >> resetContents [
	position := 0.
	readLimit := 0
]

{ #category : #accessing }
WriteStream >> isEmpty [
	^ position = 0
]

{ #category : #accessing }
WriteStream >> cr [
	self nextPut: Character cr
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
WriteStream >> tab [
	self nextPut: Character tab
]

{ #category : #accessing }
WriteStream >> space [
	self nextPut: Character space
]

{ #category : #accessing }
WriteStream >> print: anObject [
	anObject printOn: self
]

{ #category : #accessing }
WriteStream >> display: anObject [
	anObject displayOn: self
]

{ #category : #accessing }
WriteStream >> << anObject [
	anObject isString ifTrue: [self nextPutAll: anObject] ifFalse: [anObject displayOn: self]
]

{ #category : #accessing }
WriteStream >> next: n put: anObject [
	n timesRepeat: [self nextPut: anObject]
]

{ #category : #accessing }
WriteStream >> position: anInteger [
	(anInteger between: 0 and: readLimit) ifFalse: [^ self error: 'position out of range'].
	position := anInteger
]
