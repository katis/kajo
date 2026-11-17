"A Unicode scalar, immediate. Not a user-perceived character (a grapheme) until the Unicode tables exist, as Rust's char. Case mapping and classification are ASCII in 8b; every scalar above 127 that is not a separator counts as a letter."
Class {
	#name : #Character,
	#superclass : #Magnitude
}

{ #category : #accessing }
Character >> < aCharacter <Character> ^<Boolean> [
	^ self value < aCharacter value
]

{ #category : #accessing }
Character >> = anObject <Object> ^<Boolean> [
	^ self == anObject
]

{ #category : #accessing }
Character >> asCharacter ^<Self> [
	^ self
]

{ #category : #accessing }
Character >> asInteger ^<Integer> [
	^ self value
]

{ #category : #accessing }
Character >> asLowercase ^<Character> [
	^ self isUppercase ifTrue: [Character value: self value + 32] ifFalse: [self]
]

{ #category : #accessing }
Character >> asString ^<String> [
	^ String with: self
]

{ #category : #accessing }
Character >> asSymbol ^<Symbol> [
	^ self asString asSymbol
]

{ #category : #accessing }
Character >> asUppercase ^<Character> [
	^ self isLowercase ifTrue: [Character value: self value - 32] ifFalse: [self]
]

{ #category : #accessing }
Character >> codePoint ^<Integer> [
	^ self value
]

{ #category : #accessing }
Character >> digitValue ^<Integer> [
	| v |
	v := self value.
	(v between: 48 and: 57) ifTrue: [^ v - 48].
	(v between: 65 and: 90) ifTrue: [^ v - 55].
	(v between: 97 and: 122) ifTrue: [^ v - 87].
	^ -1
]

{ #category : #accessing }
Character >> displayString [
	^ self asString
]

{ #category : #accessing }
Character >> hash [
	^ self value
]

{ #category : #accessing }
Character >> isAlphaNumeric ^<Boolean> [
	^ self isLetter or: [self isDigit]
]

{ #category : #accessing }
Character >> isCharacter [
	^ true
]

{ #category : #accessing }
Character >> isDigit ^<Boolean> [
	^ self value between: 48 and: 57
]

{ #category : #accessing }
Character >> isLetter ^<Boolean> [
	^ self isUppercase or: [self isLowercase or: [self value > 127 and: [self isSeparator not]]]
]

{ #category : #accessing }
Character >> isLiteral [
	^ true
]

{ #category : #accessing }
Character >> isLowercase ^<Boolean> [
	^ self value between: 97 and: 122
]

{ #category : #accessing }
Character >> isSeparator ^<Boolean> [
	| v |
	v := self value.
	^ v = 32 or: [v = 9 or: [v = 10 or: [v = 13 or: [v = 12 or: [v = 160]]]]]
]

{ #category : #accessing }
Character >> isUppercase ^<Boolean> [
	^ self value between: 65 and: 90
]

{ #category : #accessing }
Character >> isVowel ^<Boolean> [
	^ 'aeiouAEIOU' includes: self
]

{ #category : #accessing }
Character >> printOn: aStream [
	aStream nextPut: $$; nextPut: self
]

{ #category : #accessing }
Character >> shallowCopy [
	^ self
]

{ #category : #accessing }
Character >> utf8Size ^<Integer> [
	| v |
	v := self value.
	v < 16r80 ifTrue: [^ 1].
	v < 16r800 ifTrue: [^ 2].
	v < 16r10000 ifTrue: [^ 3].
	^ 4
]

{ #category : #accessing }
Character >> value ^<Integer> [
	<primitive: 76>
	^ self primitiveFailed
]

{ #category : #accessing }
Character class >> cr ^<Character> [
	^ self value: 13
]

{ #category : #accessing }
Character class >> digitValue: anInteger <Integer> ^<Character> [
	^ '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ' scalarAt: anInteger + 1
]

{ #category : #accessing }
Character class >> lf ^<Character> [
	^ self value: 10
]

{ #category : #accessing }
Character class >> newline ^<Character> [
	^ self value: 10
]

{ #category : #accessing }
Character class >> space ^<Character> [
	^ self value: 32
]

{ #category : #accessing }
Character class >> tab ^<Character> [
	^ self value: 9
]

{ #category : #accessing }
Character class >> value: anInteger <Integer> ^<Character> [
	<primitive: 77>
	^ self error: anInteger printString , ' is not a Unicode scalar'
]
