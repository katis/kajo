"A stream over a collection. Over a sequenceable collection, positions count elements; over a String they are byte offsets at scalar boundaries, and next answers the Character there (kernel.md ''String''). position is the number of elements (bytes) before the next one."
Class {
	#name : #PositionableStream,
	#superclass : #Object,
	#instVars : [
		'collection',
		'position',
		'readLimit',
		'isText'
	]
}

{ #category : #accessing }
PositionableStream >> atEnd [
	^ position >= readLimit
]

{ #category : #accessing }
PositionableStream >> collection [
	^ collection
]

{ #category : #accessing }
PositionableStream >> contents [
	isText ifTrue: [^ collection copyFrom: 1 to: readLimit].
	^ collection copyFrom: 1 to: readLimit
]

{ #category : #accessing }
PositionableStream >> do: aBlock [
	[self atEnd] whileFalse: [aBlock value: self next]
]

{ #category : #accessing }
PositionableStream >> isEmpty [
	^ readLimit = 0
]

{ #category : #accessing }
PositionableStream >> next [
	| c |
	self atEnd ifTrue: [^ nil].
	isText ifTrue: [
		c := collection scalarAt: position + 1.
		position := position + (collection scalarSizeAt: position + 1).
		^ c].
	position := position + 1.
	^ collection at: position
]

{ #category : #accessing }
PositionableStream >> next: n [
	| s |
	s := WriteStream on: (isText ifTrue: [String new] ifFalse: [collection species new: 0]).
	n timesRepeat: [self atEnd ifFalse: [s nextPut: self next]].
	^ s contents
]

{ #category : #accessing }
PositionableStream >> peek [
	| p c |
	self atEnd ifTrue: [^ nil].
	p := position.
	c := self next.
	position := p.
	^ c
]

{ #category : #accessing }
PositionableStream >> peekFor: anObject [
	self peek = anObject ifTrue: [self next. ^ true].
	^ false
]

{ #category : #accessing }
PositionableStream >> position [
	^ position
]

{ #category : #accessing }
PositionableStream >> position: anInteger [
	(anInteger between: 0 and: readLimit) ifFalse: [^ self error: 'position out of range'].
	(isText and: [(collection isBoundary: anInteger + 1) not]) ifTrue: [^ self error: 'position inside a scalar'].
	position := anInteger
]

{ #category : #accessing }
PositionableStream >> reset [
	position := 0
]

{ #category : #accessing }
PositionableStream >> setOn: aCollection [
	collection := aCollection.
	isText := aCollection isString.
	position := 0.
	readLimit := isText ifTrue: [aCollection byteSize] ifFalse: [aCollection size]
]

{ #category : #accessing }
PositionableStream >> skip: n [
	isText ifTrue: [n timesRepeat: [self next]. ^ self].
	position := ((position + n) max: 0) min: readLimit
]

{ #category : #accessing }
PositionableStream >> skipSeparators [
	[self atEnd not and: [self peek isSeparator]] whileTrue: [self next]
]

{ #category : #accessing }
PositionableStream >> upTo: anObject [
	| s c |
	s := WriteStream on: (isText ifTrue: [String new] ifFalse: [collection species new: 0]).
	[self atEnd or: [(c := self next) = anObject]] whileFalse: [s nextPut: c].
	^ s contents
]

{ #category : #accessing }
PositionableStream >> upToEnd [
	| s |
	s := WriteStream on: (isText ifTrue: [String new] ifFalse: [collection species new: 0]).
	[self atEnd] whileFalse: [s nextPut: self next].
	^ s contents
]

{ #category : #accessing }
PositionableStream class >> on: aCollection [
	^ self basicNew setOn: aCollection
]
