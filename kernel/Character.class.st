"A Unicode scalar, immediate. Not a user-perceived character (a grapheme) until the Unicode tables exist, as Rust's char. Case mapping and classification are ASCII in 8b; every scalar above 127 that is not a separator counts as a letter."
Class {
	#name : #Character,
	#superclass : #Magnitude,
	#category : #'Kernel-Text'
}

{ #category : #accessing }
Character class >> value: anInteger [
	<primitive: 77>
	^ self error: anInteger printString , ' is not a Unicode scalar'
]

{ #category : #accessing }
Character class >> cr [
	^ self value: 13
]

{ #category : #accessing }
Character class >> lf [
	^ self value: 10
]

{ #category : #accessing }
Character class >> newline [
	^ self value: 10
]

{ #category : #accessing }
Character class >> tab [
	^ self value: 9
]

{ #category : #accessing }
Character class >> space [
	^ self value: 32
]

{ #category : #accessing }
Character class >> digitValue: anInteger [
	^ '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ' scalarAt: anInteger + 1
]

{ #category : #accessing }
Character >> value [
	<primitive: 76>
	^ self primitiveFailed
]

{ #category : #accessing }
Character >> asInteger [
	^ self value
]

{ #category : #accessing }
Character >> codePoint [
	^ self value
]

{ #category : #accessing }
Character >> asCharacter [
	^ self
]

{ #category : #accessing }
Character >> < aCharacter [
	^ self value < aCharacter value
]

{ #category : #accessing }
Character >> = anObject [
	^ self == anObject
]

{ #category : #accessing }
Character >> hash [
	^ self value
]

{ #category : #accessing }
Character >> isCharacter [
	^ true
]

{ #category : #accessing }
Character >> isLiteral [
	^ true
]

{ #category : #accessing }
Character >> isDigit [
	^ self value between: 48 and: 57
]

{ #category : #accessing }
Character >> isUppercase [
	^ self value between: 65 and: 90
]

{ #category : #accessing }
Character >> isLowercase [
	^ self value between: 97 and: 122
]

{ #category : #accessing }
Character >> isLetter [
	^ self isUppercase or: [self isLowercase or: [self value > 127 and: [self isSeparator not]]]
]

{ #category : #accessing }
Character >> isAlphaNumeric [
	^ self isLetter or: [self isDigit]
]

{ #category : #accessing }
Character >> isSeparator [
	| v |
	v := self value.
	^ v = 32 or: [v = 9 or: [v = 10 or: [v = 13 or: [v = 12 or: [v = 160]]]]]
]

{ #category : #accessing }
Character >> isVowel [
	^ 'aeiouAEIOU' includes: self
]

{ #category : #accessing }
Character >> asUppercase [
	^ self isLowercase ifTrue: [Character value: self value - 32] ifFalse: [self]
]

{ #category : #accessing }
Character >> asLowercase [
	^ self isUppercase ifTrue: [Character value: self value + 32] ifFalse: [self]
]

{ #category : #accessing }
Character >> digitValue [
	| v |
	v := self value.
	(v between: 48 and: 57) ifTrue: [^ v - 48].
	(v between: 65 and: 90) ifTrue: [^ v - 55].
	(v between: 97 and: 122) ifTrue: [^ v - 87].
	^ -1
]

{ #category : #accessing }
Character >> utf8Size [
	| v |
	v := self value.
	v < 16r80 ifTrue: [^ 1].
	v < 16r800 ifTrue: [^ 2].
	v < 16r10000 ifTrue: [^ 3].
	^ 4
]

{ #category : #accessing }
Character >> asString [
	^ String with: self
]

{ #category : #accessing }
Character >> asSymbol [
	^ self asString asSymbol
]

{ #category : #accessing }
Character >> printOn: aStream [
	aStream nextPut: $$; nextPut: self
]

{ #category : #accessing }
Character >> displayString [
	^ self asString
]

{ #category : #accessing }
Character >> shallowCopy [
	^ self
]
