"Integers of any size. SmallIntegers are immediate; beyond 62 bits the primitives answer LargePositiveIntegers and LargeNegativeIntegers, normalized back when they fit. Division that is not exact answers a Fraction."
Class {
	#name : #Integer,
	#superclass : #Number
}

{ #category : #arithmetic }
Integer >> / aNumber <Number> ^<Number> [
	aNumber isInteger ifTrue: [
		aNumber = 0 ifTrue: [^ ZeroDivide new dividend: self; signal: 'division by zero'].
		^ (Fraction numerator: self denominator: aNumber) normalized].
	^ self retry: #/ coercing: aNumber
]

{ #category : #arithmetic }
Integer >> << n <Integer> ^<Integer> [
	^ self bitShift: n
]

{ #category : #arithmetic }
Integer >> >> n <Integer> ^<Integer> [
	^ self bitShift: n negated
]

{ #category : #arithmetic }
Integer >> asCharacter ^<Character> [
	^ Character value: self
]

{ #category : #arithmetic }
Integer >> factorial ^<Integer> [
	| r |
	self < 0 ifTrue: [^ self error: 'factorial of a negative number'].
	r := 1.
	2 to: self do: [:i | r := r * i].
	^ r
]

{ #category : #arithmetic }
Integer >> gcd: anInteger <Integer> ^<Integer> [
	| a b t |
	a := self abs. b := anInteger abs.
	[b = 0] whileFalse: [t := a \\ b. a := b. b := t].
	^ a
]

{ #category : #arithmetic }
Integer >> isPrime ^<Boolean> [
	| i |
	self < 2 ifTrue: [^ false].
	i := 2.
	[i * i <= self] whileTrue: [self \\ i = 0 ifTrue: [^ false]. i := i + 1].
	^ true
]

{ #category : #arithmetic }
Integer >> lcm: anInteger <Integer> ^<Integer> [
	^ (self * anInteger) abs // (self gcd: anInteger)
]

{ #category : #arithmetic }
Integer >> sqrtFloor ^<Integer> [
	| lo hi mid |
	self < 0 ifTrue: [^ self error: 'sqrtFloor of a negative number'].
	lo := 0. hi := self + 1.
	[hi - lo > 1] whileTrue: [
		mid := lo + hi // 2.
		mid * mid <= self ifTrue: [lo := mid] ifFalse: [hi := mid]].
	^ lo
]

{ #category : #arithmetic }
Integer >> timesRepeat: aBlock <[^Dynamic]> ^<Self> [
	| i |
	i := 1.
	[i <= self] whileTrue: [aBlock value. i := i + 1]
]

{ #category : #coercion }
Integer >> asFraction ^<Fraction> [
	^ Fraction numerator: self denominator: 1
]

{ #category : #printing }
Integer >> asString ^<String> [
	^ self printString
]

{ #category : #printing }
Integer >> printOn: aStream <WriteStream> base: base <Integer> ^<Self> [
	aStream nextPutAll: (self printString: base)
]

{ #category : #printing }
Integer >> printPaddedWith: aCharacter <Character> to: width <Integer> ^<String> [
	| s |
	s := self printString.
	^ (String new: width - s scalarCount withAll: aCharacter) , s
]

{ #category : #printing }
Integer >> printString ^<String> [
	^ self printString: 10
]

{ #category : #printing }
Integer >> printString: base <Integer> ^<String> [
	"The digits counted first, then written from the right into a ByteArray that becomes the String: no stream and no reversal, a few sends a number rather than a few a digit (the collections-speed module). A LargeInteger is divided twice as often as it would be with a stream."
	| n k d bytes |
	(base < 2 or: [base > 36]) ifTrue: [^ self error: 'the base must be from 2 to 36'].
	self = 0 ifTrue: [^ '0'].
	n := self abs.
	k := self < 0 ifTrue: [1] ifFalse: [0].
	d := n.
	[d > 0] whileTrue: [
		k := k + 1.
		d := d // base].
	bytes := ByteArray new: k.
	[n > 0] whileTrue: [
		d := n \\ base.
		bytes at: k put: (d < 10 ifTrue: [48 + d] ifFalse: [55 + d]).
		k := k - 1.
		n := n // base].
	self < 0 ifTrue: [bytes at: 1 put: 45].
	^ bytes asStringValidating
]

{ #category : #printing }
Integer >> storeString ^<String> [
	^ self printString
]

{ #category : #testing }
Integer >> even [
	^ (self bitAnd: 1) = 0
]

{ #category : #testing }
Integer >> isInteger ^<Boolean> [
	^ true
]

{ #category : #truncation }
Integer >> asInteger ^<Self> [
	^ self
]

{ #category : #truncation }
Integer >> ceiling [
	^ self
]

{ #category : #truncation }
Integer >> denominator ^<Integer> [
	^ 1
]

{ #category : #truncation }
Integer >> floor [
	^ self
]

{ #category : #truncation }
Integer >> numerator ^<Integer> [
	^ self
]

{ #category : #truncation }
Integer >> rounded [
	^ self
]

{ #category : #truncation }
Integer >> truncated [
	^ self
]

{ #category : #printing }
Integer class >> readFrom: aString <String> ^<Integer | Nil> [
	^ aString asInteger
]
