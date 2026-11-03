"One String type: an immutable sequence of Unicode scalars stored as valid UTF-8 (kernel.md, ADR 0009 section 8). There is no at:put: and no size: positions are 1-based byte offsets valid only at scalar boundaries (Rust's slicing), iteration is by scalar (do: yields Characters), utf8 answers a constant-time byte view, scalarCount counts. Strings are built with , and WriteStream. Equality and hash are over the bytes: canonically equivalent Strings in different normal forms are not equal until normalization exists. Comparison is by scalar value (byte order is scalar order in UTF-8); case mapping is ASCII."
Class {
	#name : #String,
	#superclass : #ArrayedCollection,
	#category : #'Kernel-Text',
	#type : #bytes
}

{ #category : #'instance creation' }
String class >> new [
	"The empty String."
	^ self basicNew: 0
]

{ #category : #'instance creation' }
String class >> new: n [
	^ self shouldNotImplement
]

{ #category : #'instance creation' }
String class >> new: n withAll: aCharacter [
	| s |
	s := WriteStream on: String new.
	n timesRepeat: [s nextPut: aCharacter].
	^ s contents
]

{ #category : #'instance creation' }
String class >> with: aCharacter [
	^ (WriteStream on: String new) nextPut: aCharacter; contents
]

{ #category : #'instance creation' }
String class >> with: a with: b [
	^ (WriteStream on: String new) nextPut: a; nextPut: b; contents
]

{ #category : #'instance creation' }
String class >> streamContents: aBlock [
	| s |
	s := WriteStream on: String new.
	aBlock value: s.
	^ s contents
]

{ #category : #'instance creation' }
String class >> fromUtf8: aByteArray [
	^ aByteArray asStringValidating
]

{ #category : #'instance creation' }
String class >> cr [
	^ self with: Character cr
]

{ #category : #'instance creation' }
String class >> lf [
	^ self with: Character lf
]

{ #category : #'instance creation' }
String class >> tab [
	^ self with: Character tab
]

{ #category : #'instance creation' }
String class >> space [
	^ self with: Character space
]

{ #category : #bytes }
String >> byteSize [
	<primitive: 133>
	^ 0
]

{ #category : #bytes }
String >> utf8Size [
	^ self byteSize
]

{ #category : #bytes }
String >> byteAt: offset [
	<primitive: 132>
	^ self indexError: offset
]

{ #category : #bytes }
String >> utf8 [
	"A constant-time, read-only view of the bytes."
	^ Utf8View on: self
]

{ #category : #bytes }
String >> asByteArray [
	| b |
	b := ByteArray new: self byteSize.
	1 to: b size do: [:i | b at: i put: (self byteAt: i)].
	^ b
]

{ #category : #scalars }
String >> scalars [
	^ self
]

{ #category : #scalars }
String >> scalarCount [
	<primitive: 126>
	^ self primitiveFailed
]

{ #category : #scalars }
String >> scalarAt: offset [
	"The Character starting at this byte offset; fails inside a scalar or past the end."
	<primitive: 124>
	^ self boundaryError: offset
]

{ #category : #scalars }
String >> scalarSizeAt: offset [
	<primitive: 136>
	^ self boundaryError: offset
]

{ #category : #scalars }
String >> isBoundary: offset [
	"Whether the offset starts a scalar (the end, byteSize + 1, included)."
	<primitive: 125>
	^ false
]

{ #category : #scalars }
String >> boundaryError: offset [
	^ SubscriptOutOfBounds new signal: offset printString , ' is not a scalar boundary of ' , self printString
]

{ #category : #scalars }
String >> previousBoundary: offset [
	| j |
	j := offset - 1.
	[j > 1 and: [(self isBoundary: j) not]] whileTrue: [j := j - 1].
	^ j
]

{ #category : #scalars }
String >> size [
	^ self error: 'String has no size: use scalarCount (scalars) or byteSize (bytes)'
]

{ #category : #scalars }
String >> at: index [
	^ self error: 'String has no integer index: use scalarAt: with a byte offset, or do:'
]

{ #category : #scalars }
String >> at: index put: anObject [
	^ self error: 'Strings are immutable: build them with , or a WriteStream'
]

{ #category : #enumerating }
String >> do: aBlock [
	| i end |
	i := 1.
	end := self byteSize.
	[i <= end] whileTrue: [
		aBlock value: (self scalarAt: i).
		i := i + (self scalarSizeAt: i)]
]

{ #category : #enumerating }
String >> reverseDo: aBlock [
	| i |
	i := self byteSize + 1.
	[i > 1] whileTrue: [
		i := self previousBoundary: i.
		aBlock value: (self scalarAt: i)]
]

{ #category : #enumerating }
String >> keysAndValuesDo: aBlock [
	"The byte offset and the Character of each scalar."
	| i end |
	i := 1.
	end := self byteSize.
	[i <= end] whileTrue: [
		aBlock value: i value: (self scalarAt: i).
		i := i + (self scalarSizeAt: i)]
]

{ #category : #enumerating }
String >> collect: aBlock [
	"A String: the block answers Characters."
	| s |
	s := WriteStream on: String new.
	self do: [:c | s nextPut: (aBlock value: c)].
	^ s contents
]

{ #category : #enumerating }
String >> select: aBlock [
	| s |
	s := WriteStream on: String new.
	self do: [:c | (aBlock value: c) ifTrue: [s nextPut: c]].
	^ s contents
]

{ #category : #enumerating }
String >> asArray [
	| out |
	out := OrderedCollection new.
	self do: [:c | out add: c].
	^ out asArray
]

{ #category : #enumerating }
String >> reversed [
	| s |
	s := WriteStream on: String new.
	self reverseDo: [:c | s nextPut: c].
	^ s contents
]

{ #category : #testing }
String >> isEmpty [
	^ self byteSize = 0
]

{ #category : #testing }
String >> notEmpty [
	^ self byteSize > 0
]

{ #category : #testing }
String >> isString [
	^ true
]

{ #category : #testing }
String >> isLiteral [
	^ true
]

{ #category : #testing }
String >> first [
	self isEmpty ifTrue: [^ self error: 'the String is empty'].
	^ self scalarAt: 1
]

{ #category : #testing }
String >> last [
	self isEmpty ifTrue: [^ self error: 'the String is empty'].
	^ self scalarAt: (self previousBoundary: self byteSize + 1)
]

{ #category : #testing }
String >> first: n [
	"The first n scalars."
	| i |
	i := 1.
	n timesRepeat: [i := i + (self scalarSizeAt: i)].
	^ self copyFrom: 1 to: i - 1
]

{ #category : #testing }
String >> allButFirst [
	self isEmpty ifTrue: [^ self].
	^ self copyFrom: 1 + (self scalarSizeAt: 1) to: self byteSize
]

{ #category : #testing }
String >> allButLast [
	self isEmpty ifTrue: [^ self].
	^ self copyFrom: 1 to: (self previousBoundary: self byteSize + 1) - 1
]

{ #category : #comparing }
String >> = anObject [
	"Equal bytes; a Symbol is never equal to a String."
	^ (anObject isString and: [anObject isSymbol not and: [self isSymbol not]]) and: [self sameBytesAs: anObject]
]

{ #category : #comparing }
String >> hash [
	<primitive: 122>
	^ self primitiveFailed
]

{ #category : #comparing }
String >> sameBytesAs: aString [
	<primitive: 121>
	^ false
]

{ #category : #comparing }
String >> compare: aString [
	"-1, 0 or 1: byte order, which is scalar order."
	<primitive: 120>
	^ self error: 'compare: takes a String'
]

{ #category : #comparing }
String >> < aString [
	^ (self compare: aString) < 0
]

{ #category : #comparing }
String >> > aString [
	^ (self compare: aString) > 0
]

{ #category : #comparing }
String >> <= aString [
	^ (self compare: aString) <= 0
]

{ #category : #comparing }
String >> >= aString [
	^ (self compare: aString) >= 0
]

{ #category : #copying }
String >> , aString [
	<primitive: 123>
	^ self error: ', takes a String (use printString or displayString for other objects)'
]

{ #category : #copying }
String >> copyFrom: start to: stop [
	"Bytes start to stop, both at scalar boundaries (stop the last byte of a scalar)."
	<primitive: 127>
	^ self boundaryError: start
]

{ #category : #copying }
String >> copyWith: aCharacter [
	^ self , aCharacter asString
]

{ #category : #copying }
String >> copyReplaceAll: old with: new [
	^ self replaceAll: old with: new
]

{ #category : #copying }
String >> postCopy [
	^ self
]

{ #category : #copying }
String >> shallowCopy [
	^ self
]

{ #category : #searching }
String >> indexOf: aCharacter [
	"The byte offset of the first occurrence, 0 if none."
	self keysAndValuesDo: [:i :c | c = aCharacter ifTrue: [^ i]].
	^ 0
]

{ #category : #searching }
String >> indexOfSubstring: aString startingAt: offset [
	<primitive: 134>
	^ self boundaryError: offset
]

{ #category : #searching }
String >> indexOfSubstring: aString [
	^ self indexOfSubstring: aString startingAt: 1
]

{ #category : #searching }
String >> includesSubstring: aString [
	^ (self indexOfSubstring: aString startingAt: 1) > 0
]

{ #category : #searching }
String >> beginsWith: aString [
	aString byteSize > self byteSize ifTrue: [^ false].
	1 to: aString byteSize do: [:i | (self byteAt: i) = (aString byteAt: i) ifFalse: [^ false]].
	^ true
]

{ #category : #searching }
String >> endsWith: aString [
	| d |
	d := self byteSize - aString byteSize.
	d < 0 ifTrue: [^ false].
	1 to: aString byteSize do: [:i | (self byteAt: d + i) = (aString byteAt: i) ifFalse: [^ false]].
	^ true
]

{ #category : #searching }
String >> occurrencesOf: aCharacter [
	^ self count: [:c | c = aCharacter]
]

{ #category : #converting }
String >> asString [
	^ self
]

{ #category : #converting }
String >> displayString [
	^ self
]

{ #category : #converting }
String >> asSymbol [
	<primitive: 129>
	^ self primitiveFailed
]

{ #category : #converting }
String >> asUppercase [
	^ self collect: [:c | c asUppercase]
]

{ #category : #converting }
String >> asLowercase [
	^ self collect: [:c | c asLowercase]
]

{ #category : #converting }
String >> asInteger [
	"The integer the leading digits (after an optional -) name, nil if there are none."
	| n neg any |
	n := 0. neg := false. any := false.
	self keysAndValuesDo: [:i :c |
		(i = 1 and: [c = $-]) ifTrue: [neg := true] ifFalse: [
			c isDigit ifFalse: [^ any ifTrue: [neg ifTrue: [n negated] ifFalse: [n]] ifFalse: [nil]].
			any := true.
			n := n * 10 + c digitValue]].
	any ifFalse: [^ nil].
	^ neg ifTrue: [n negated] ifFalse: [n]
]

{ #category : #converting }
String >> asFloat [
	"The double a decimal String names (Swift's reading)."
	<primitive: 78>
	^ self error: self printString , ' is not a float'
]

{ #category : #converting }
String >> asNumber [
	((self includes: $.) or: [self includes: $e]) ifTrue: [^ self asFloat].
	^ self asInteger
]

{ #category : #converting }
String >> trimmed [
	| start stop |
	start := 1.
	[start <= self byteSize and: [(self scalarAt: start) isSeparator]] whileTrue: [start := start + (self scalarSizeAt: start)].
	stop := self byteSize + 1.
	[stop > start and: [(self scalarAt: (self previousBoundary: stop)) isSeparator]] whileTrue: [stop := self previousBoundary: stop].
	^ self copyFrom: start to: stop - 1
]

{ #category : #converting }
String >> replaceAll: old with: new [
	"A new String with every occurrence of the String old replaced by new."
	| s i j |
	old isEmpty ifTrue: [^ self].
	s := WriteStream on: String new.
	i := 1.
	[(j := self indexOfSubstring: old startingAt: i) > 0] whileTrue: [
		s nextPutAll: (self copyFrom: i to: j - 1); nextPutAll: new.
		i := j + old byteSize].
	s nextPutAll: (self copyFrom: i to: self byteSize).
	^ s contents
]

{ #category : #converting }
String >> splitOn: separator [
	"The pieces between occurrences of separator (a String or a Character), empty ones included."
	| sep out i j |
	sep := separator isCharacter ifTrue: [separator asString] ifFalse: [separator].
	out := OrderedCollection new.
	i := 1.
	[(j := self indexOfSubstring: sep startingAt: i) > 0] whileTrue: [
		out add: (self copyFrom: i to: j - 1).
		i := j + sep byteSize].
	out add: (self copyFrom: i to: self byteSize).
	^ out asArray
]

{ #category : #converting }
String >> lines [
	"The lines, separated by LF, CR LF or CR; no empty last line for a trailing separator."
	| out s |
	out := OrderedCollection new.
	s := WriteStream on: String new.
	self readStream in: [:r |
		[r atEnd] whileFalse: [ | c |
			c := r next.
			(c value = 10 or: [c value = 13])
				ifTrue: [
					(c value = 13 and: [r peek notNil and: [r peek value = 10]]) ifTrue: [r next].
					out add: s contents.
					s := WriteStream on: String new]
				ifFalse: [s nextPut: c]]].
	s contents isEmpty ifFalse: [out add: s contents].
	^ out asArray
]

{ #category : #converting }
String >> substrings [
	"The pieces between runs of separators."
	| out s |
	out := OrderedCollection new.
	s := WriteStream on: String new.
	self do: [:c |
		c isSeparator
			ifTrue: [s contents isEmpty ifFalse: [out add: s contents. s := WriteStream on: String new]]
			ifFalse: [s nextPut: c]].
	s contents isEmpty ifFalse: [out add: s contents].
	^ out asArray
]

{ #category : #converting }
String >> species [
	^ String
]

{ #category : #converting }
String >> readStream [
	^ ReadStream on: self
]

{ #category : #printing }
String >> printOn: aStream [
	aStream nextPut: $'.
	self do: [:c | c = $' ifTrue: [aStream nextPut: $']. aStream nextPut: c].
	aStream nextPut: $'
]

{ #category : #printing }
String >> displayOn: aStream [
	aStream nextPutAll: self
]

{ #category : #printing }
String >> storeString [
	^ self printString
]
