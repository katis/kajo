"JSON for the development protocol (module 9b). The reader takes what the target's transport wrote (canonical JSON of a request it checked, Sources/KajoDev/Request.swift) and answers nil, true, false, Integers, Floats, Strings, Arrays and JsonObjects; it signals an Error on anything else. The writer writes those and Symbols, Characters, OrderedCollections and Dictionaries (keys sorted by their printString); any other object as its printString."
Class {
	#name : #Json,
	#superclass : #Object,
	#instVars : [
		'source',
		'position'
	]
}

{ #category : #reading }
Json >> atEnd [
	^ position > source byteSize
]

{ #category : #reading }
Json >> byte [
	^ position <= source byteSize ifTrue: [source byteAt: position] ifFalse: [0]
]

{ #category : #reading }
Json >> expect: aByte [
	self byte = aByte ifFalse: [^ self fail: 'expected ' , (String with: (Character value: aByte))].
	position := position + 1
]

{ #category : #reading }
Json >> fail: aString [
	^ self error: 'JSON: ' , aString , ' at byte ' , position printString
]

{ #category : #reading }
Json >> hex4 [
	| v |
	v := 0.
	4 timesRepeat: [ | b d |
		b := self byte.
		d := (b between: 48 and: 57)
			ifTrue: [b - 48]
			ifFalse: [(b between: 65 and: 70) ifTrue: [b - 55] ifFalse: [(b between: 97 and: 102) ifTrue: [b - 87] ifFalse: [^ self fail: 'a bad \u escape']]].
		v := v * 16 + d.
		position := position + 1].
	^ v
]

{ #category : #reading }
Json >> literal: aString value: anObject [
	(source copyFrom: position to: (position + aString byteSize - 1 min: source byteSize)) = aString ifFalse: [^ self fail: 'expected ' , aString].
	position := position + aString byteSize.
	^ anObject
]

{ #category : #reading }
Json >> number [
	| start isInteger text |
	start := position.
	isInteger := true.
	self byte = 45 ifTrue: [position := position + 1].
	[self byte between: 48 and: 57] whileTrue: [position := position + 1].
	(self byte = 46 or: [self byte = 101 or: [self byte = 69]]) ifTrue: [
		isInteger := false.
		[(self byte between: 48 and: 57) or: [#(46 101 69 43 45) includes: self byte]] whileTrue: [position := position + 1]].
	text := source copyFrom: start to: position - 1.
	text isEmpty ifTrue: [^ self fail: 'expected a number'].
	isInteger ifTrue: [^ (text asInteger) ifNil: [self fail: 'a bad number']].
	^ text asFloat
]

{ #category : #reading }
Json >> readArray [
	| out |
	self expect: 91.
	out := OrderedCollection new.
	self skip.
	self byte = 93 ifTrue: [position := position + 1. ^ out asArray].
	[true] whileTrue: [
		out add: self readValue.
		self skip.
		self byte = 93 ifTrue: [position := position + 1. ^ out asArray].
		self expect: 44]
]

{ #category : #reading }
Json >> readObject [
	| out key |
	self expect: 123.
	out := JsonObject new.
	self skip.
	self byte = 125 ifTrue: [position := position + 1. ^ out].
	[true] whileTrue: [
		self skip.
		key := self readString.
		self skip.
		self expect: 58.
		out at: key put: self readValue.
		self skip.
		self byte = 125 ifTrue: [position := position + 1. ^ out].
		self expect: 44]
]

{ #category : #reading }
Json >> readString [
	| out b |
	self expect: 34.
	out := WriteStream on: (ByteArray new: 16).
	[(b := self byte) = 34] whileFalse: [
		position > source byteSize ifTrue: [^ self fail: 'an unterminated string'].
		b = 92
			ifTrue: [ | e |
				position := position + 1.
				e := self byte.
				position := position + 1.
				e = 117
					ifTrue: [ | c bytes |
						c := Character value: self hex4.
						bytes := (String with: c) asByteArray.
						bytes do: [:x | out nextPut: x]]
					ifFalse: [
						out nextPut: (e = 110 ifTrue: [10] ifFalse: [e = 116 ifTrue: [9] ifFalse: [e = 114 ifTrue: [13] ifFalse: [e = 98 ifTrue: [8] ifFalse: [e = 102 ifTrue: [12] ifFalse: [e]]]]])]]
			ifFalse: [out nextPut: b. position := position + 1]].
	position := position + 1.
	^ out contents asString
]

{ #category : #reading }
Json >> readValue [
	| b |
	self skip.
	b := self byte.
	b = 123 ifTrue: [^ self readObject].
	b = 91 ifTrue: [^ self readArray].
	b = 34 ifTrue: [^ self readString].
	b = 116 ifTrue: [^ self literal: 'true' value: true].
	b = 102 ifTrue: [^ self literal: 'false' value: false].
	b = 110 ifTrue: [^ self literal: 'null' value: nil].
	(b = 45 or: [b between: 48 and: 57]) ifTrue: [^ self number].
	^ self fail: 'expected a value'
]

{ #category : #reading }
Json >> setSource: aString [
	source := aString.
	position := 1
]

{ #category : #reading }
Json >> skip [
	[#(32 9 10 13) includes: self byte] whileTrue: [position := position + 1]
]

{ #category : #reading }
Json class >> read: aString [
	"The value aString holds (the whole of it, blanks around allowed); aString may be an Array of the text's pieces (module 9c: a line longer than one object, JsonText)."
	| r v |
	r := self new setSource: (aString isString ifTrue: [aString] ifFalse: [JsonText pieces: aString]).
	v := r readValue.
	r skip.
	r atEnd ifFalse: [^ self error: 'JSON: text after the value'].
	^ v
]

{ #category : #writing }
Json class >> bytes: aString on: aStream [
	1 to: aString byteSize do: [:i | aStream nextPut: (aString byteAt: i)]
]

{ #category : #writing }
Json class >> write: anObject [
	"The JSON text of anObject, a String."
	| out |
	out := WriteStream on: (ByteArray new: 64).
	self write: anObject on: out depth: 0.
	^ out contents asString
]

{ #category : #writing }
Json class >> write: anObject on: aStream depth: n [
	anObject isNil ifTrue: [^ self bytes: 'null' on: aStream].
	anObject == true ifTrue: [^ self bytes: 'true' on: aStream].
	anObject == false ifTrue: [^ self bytes: 'false' on: aStream].
	n > 32 ifTrue: [^ self writeString: '...' on: aStream].
	anObject isInteger ifTrue: [^ self bytes: anObject printString on: aStream].
	anObject isFloat ifTrue: [
		anObject isFinite ifFalse: [^ self bytes: 'null' on: aStream].
		^ self bytes: anObject printString on: aStream].
	(anObject isString or: [anObject isSymbol]) ifTrue: [^ self writeString: anObject asString on: aStream].
	anObject isCharacter ifTrue: [^ self writeString: (String with: anObject) on: aStream].
	(anObject isKindOf: JsonObject) ifTrue: [
		aStream nextPut: 123.
		anObject keys doWithIndex: [:k :i |
			i > 1 ifTrue: [aStream nextPut: 44].
			self writeString: k on: aStream.
			aStream nextPut: 58.
			self write: (anObject at: k) on: aStream depth: n + 1].
		^ aStream nextPut: 125].
	(anObject isKindOf: Dictionary) ifTrue: [ | sorted |
		sorted := anObject keys asArray sort: [:a :b | a printString <= b printString].
		aStream nextPut: 123.
		sorted doWithIndex: [:k :i |
			i > 1 ifTrue: [aStream nextPut: 44].
			self writeString: (k isString ifTrue: [k asString] ifFalse: [k printString]) on: aStream.
			aStream nextPut: 58.
			self write: (anObject at: k) on: aStream depth: n + 1].
		^ aStream nextPut: 125].
	((anObject isKindOf: Array) or: [anObject isKindOf: OrderedCollection]) ifTrue: [
		aStream nextPut: 91.
		anObject doWithIndex: [:x :i |
			i > 1 ifTrue: [aStream nextPut: 44].
			self write: x on: aStream depth: n + 1].
		^ aStream nextPut: 93].
	^ self writeString: anObject printString on: aStream
]

{ #category : #writing }
Json class >> writePieces: anObject [
	"The JSON text of anObject as ByteArrays of at most 16 KiB each, in order (module 9c: a reply longer than one object can be; primitive 161 joins them)."
	| out |
	out := JsonPieceStream new.
	self write: anObject on: out depth: 0.
	^ out pieces
]

{ #category : #writing }
Json class >> writeString: aString on: aStream [
	"A JSON string: the bytes of aString with the quote, the backslash and the control characters escaped (Sources/KajoDev/JSON.swift writes them alike)."
	| hex |
	hex := '0123456789abcdef'.
	aStream nextPut: 34.
	1 to: aString byteSize do: [:i | | b |
		b := aString byteAt: i.
		b = 34 ifTrue: [aStream nextPut: 92; nextPut: 34] ifFalse: [
		b = 92 ifTrue: [aStream nextPut: 92; nextPut: 92] ifFalse: [
		b = 10 ifTrue: [aStream nextPut: 92; nextPut: 110] ifFalse: [
		b = 13 ifTrue: [aStream nextPut: 92; nextPut: 114] ifFalse: [
		b = 9 ifTrue: [aStream nextPut: 92; nextPut: 116] ifFalse: [
		b < 32
			ifTrue: [aStream nextPut: 92; nextPut: 117; nextPut: 48; nextPut: 48;
				nextPut: (hex byteAt: (b bitShift: -4) + 1); nextPut: (hex byteAt: (b bitAnd: 15) + 1)]
			ifFalse: [aStream nextPut: b]]]]]]].
	aStream nextPut: 34
]
