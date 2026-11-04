"A double. Most are SmallFloats (immediate, about 1e-77 to 1e77 with the full mantissa); the rest (larger, smaller, NaN, infinities) are boxed in 8 bytes. Arithmetic is IEEE."
Class {
	#name : #Float,
	#superclass : #Number,
	#classVars : [
		'Infinity',
		'NegativeInfinity',
		'NaN'
	],
	#category : #'Kernel-Numbers',
	#type : #bytes
}

{ #category : #arithmetic }
Float >> + aNumber [
	<primitive: 60>
	^ self retry: #+ coercing: aNumber
]

{ #category : #arithmetic }
Float >> - aNumber [
	<primitive: 61>
	^ self retry: #- coercing: aNumber
]

{ #category : #arithmetic }
Float >> * aNumber [
	<primitive: 62>
	^ self retry: #* coercing: aNumber
]

{ #category : #arithmetic }
Float >> / aNumber [
	<primitive: 63>
	aNumber = 0 ifTrue: [^ ZeroDivide new dividend: self; signal: 'division by zero'].
	^ self retry: #/ coercing: aNumber
]

{ #category : #arithmetic }
Float >> < aNumber [
	<primitive: 64>
	^ self retry: #< coercing: aNumber
]

{ #category : #arithmetic }
Float >> > aNumber [
	<primitive: 65>
	^ self retry: #> coercing: aNumber
]

{ #category : #arithmetic }
Float >> <= aNumber [
	<primitive: 66>
	^ self retry: #<= coercing: aNumber
]

{ #category : #arithmetic }
Float >> >= aNumber [
	<primitive: 67>
	^ self retry: #>= coercing: aNumber
]

{ #category : #arithmetic }
Float >> = aNumber [
	<primitive: 68>
	^ self retry: #= coercing: aNumber
]

{ #category : #arithmetic }
Float >> ~= aNumber [
	<primitive: 69>
	^ self retry: #~= coercing: aNumber
]

{ #category : #arithmetic }
Float >> // aNumber [
	^ (self / aNumber) floor
]

{ #category : #arithmetic }
Float >> negated [
	^ 0.0 - self
]

{ #category : #truncation }
Float >> truncated [
	<primitive: 70>
	^ self error: 'cannot truncate ' , self printString
]

{ #category : #truncation }
Float >> fractionPart [
	<primitive: 71>
	^ self primitiveFailed
]

{ #category : #truncation }
Float >> exponent [
	<primitive: 72>
	^ self primitiveFailed
]

{ #category : #truncation }
Float >> timesTwoPower: anInteger [
	<primitive: 73>
	^ self primitiveFailed
]

{ #category : #truncation }
Float >> sqrt [
	<primitive: 74>
	^ self negative ifTrue: [Float nan] ifFalse: [self primitiveFailed]
]

{ #category : #truncation }
Float >> rounded [
	^ (self + (self negative ifTrue: [-0.5] ifFalse: [0.5])) truncated
]

{ #category : #testing }
Float >> isFloat [
	^ true
]

{ #category : #testing }
Float >> isNaN [
	^ self ~= self
]

{ #category : #testing }
Float >> isInfinite [
	^ self isNaN not and: [(self - self) isNaN]
]

{ #category : #testing }
Float >> isFinite [
	^ (self - self) = 0.0
]

{ #category : #testing }
Float >> hash [
	self isFinite ifFalse: [^ 0].
	self fractionPart = 0.0 ifTrue: [^ self truncated hash].
	^ (self * 1048576.0) truncated hash
]

{ #category : #coercion }
Float >> generality [
	^ 40
]

{ #category : #coercion }
Float >> coerce: aNumber [
	^ aNumber asFloat
]

{ #category : #coercion }
Float >> asFloat [
	^ self
]

{ #category : #coercion }
Float >> asFraction [
	"The exact value of the double."
	| e m |
	self isFinite ifFalse: [^ self error: 'not a finite number'].
	self = 0.0 ifTrue: [^ 0].
	e := self exponent.
	m := (self timesTwoPower: 52 - e) truncated.
	^ e >= 52 ifTrue: [m bitShift: e - 52] ifFalse: [(Fraction numerator: m denominator: (1 bitShift: 52 - e)) normalized]
]

{ #category : #printing }
Float >> printString [
	"The shortest digits that read back as the same double."
	<primitive: 75>
	^ self primitiveFailed
]

{ #category : #printing }
Float >> printOn: aStream [
	aStream nextPutAll: self printString
]

{ #category : #printing }
Float class >> pi [
	^ 3.141592653589793
]

{ #category : #printing }
Float class >> e [
	^ 2.718281828459045
]

{ #category : #printing }
Float class >> initialize [
	"The non-finite constants, made once (class variables, module 8d)."
	Infinity := 1.0e300 * 1.0e300.
	NegativeInfinity := 0.0 - Infinity.
	NaN := Infinity - Infinity
]

{ #category : #printing }
Float class >> infinity [
	^ Infinity ifNil: [self initialize. Infinity]
]

{ #category : #printing }
Float class >> negativeInfinity [
	^ NegativeInfinity ifNil: [self initialize. NegativeInfinity]
]

{ #category : #printing }
Float class >> nan [
	^ NaN ifNil: [self initialize. NaN]
]

{ #category : #printing }
Float class >> readFrom: aString [
	^ aString asFloat
]
