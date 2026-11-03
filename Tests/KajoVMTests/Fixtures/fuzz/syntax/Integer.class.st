"Integers of any size. SmallIntegers are immediate; beyond 62 bits the primitives answer LargePositiveIntegers and LargeNegativeIntegers, normalized back when they fit. Division that is not exact answers a Fraction."
Class {
	#name : #Integer,
	#superclass : #Number,
	#category : #'Kernel-Numbers'
}

{ #category : #arithmetic }
Integer >> / aNumber [
	aNumber isInteger ifTrue: [
		aNumber = 0 ifTrue: [^ ZeroDivide new dividend: self; signal: 'division by zero'].
		^ (Fraction numerator: self denominator: aNumber) normalized].
	^ self retry: #/ coercing: aNumber
]

{ #category : #arithmetic }
Integer >> gcd: anInteger [
	| a b t |
	a := self abs. b := anInteger abs.
	[b = 0] whileFalse: [t := a \\ b. a := b. b := t].
	^ a
]

{ #category : #arithmetic }
Integer >> lcm: anInteger [
	^ (self * anInteger) abs // (self gcd: anInteger)
]

{ #category : #arithmetic }
Integer >> factorial [
	| r |
	self < 0 ifTrue: [^ self error: 'factorial of a negative number'].
	r := 1.
	2 to: self do: [:i | r := r * i].
	^ r
]

{ #category : #arithmetic }
Integer >> isPrime [
	| i |
	self < 2 ifTrue: [^ false].
	i := 2.
	[i * i <= self] whileTrue: [self \\ i = 0 ifTrue: [^ false]. i := i + 1].
	^ true
]

{ #category : #arithmetic }
Integer >> sqrtFloor [
	| lo hi mid |
	self < 0 ifTrue: [^ self error: 'sqrtFloor of a negative number'].
	lo := 0. hi := self + 1.
	[hi - lo > 1] whileTrue: [
		mid := lo + hi // 2.
		mid * mid <= self ifTrue: [lo := mid] ifFalse: [hi := mid]].
	^ lo
]

{ #category : #arithmetic }
Integer >> << n [
	^ self bitShift: n
]

{ #category : #arithmetic }
Integer >> >> n [
	^ self bitShift: n negated
]

{ #category : #arithmetic }
Integer >> timesRepeat: aBlock [
	| i |
	i := 1.
	[i <= self] whileTrue: [aBlock value. i := i + 1]
]

{ #category : #arithmetic }
Integer >> asCharacter [
	^ Character value: self
]

{ #category : #testing }
Integer >> isInteger [
	^ true
]

{ #category : #testing }
Integer >> even [
	^ (self bitAnd: 1) = 0
]

{ #category : #truncation }
Integer >> truncated [
	^ self
]

{ #category : #truncation }
Integer >> rounded [
	^ self
]

{ #category : #truncation }
Integer >> floor [
	^ self
]

{ #category : #truncation }
Integer >> ceiling [
	^ self
]

{ #category : #truncation }
Integer >> numerator [
	^ self
]

{ #category : #truncation }
Integer >> denominator [
	^ 1
]

{ #category : #truncation }
Integer >> asInteger [
	^ self
]

{ #category : #coercion }
Integer >> asFraction [
	^ Fraction numerator: self denominator: 1
]

{ #category : #printing }
Integer >> printString [
	^ self printString: 10
]

{ #category : #printing }
Integer >> printString: base [
	| s n digits |
	self = 0 ifTrue: [^ '0'].
	digits := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'.
	s := WriteStream on: String new.
	n := self abs.
	[n > 0] whileTrue: [
		s nextPut: (digits scalarAt: n \\ base + 1).
		n := n // base].
	self < 0 ifTrue: [s nextPut: $-].
	^ s contents reversed
]

{ #category : #printing }
Integer >> printOn: aStream base: base [
	aStream nextPutAll: (self printString: base)
]

{ #category : #printing }
Integer >> printPaddedWith: aCharacter to: width [
	| s |
	s := self printString.
	^ (String new: width - s scalarCount withAll: aCharacter) , s
]

{ #category : #printing }
Integer >> storeString [
	^ self printString
]

{ #category : #printing }
Integer >> asString [
	^ self printString
]

{ #category : #printing }
Integer class >> readFrom: aString [
	^ aString asInteger
]
