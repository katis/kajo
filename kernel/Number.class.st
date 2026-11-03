"The number tower: SmallInteger, LargePositiveInteger and LargeNegativeInteger, Fraction, Float and SmallFloat. A primitive that cannot answer for a mixed pair falls back to retry:coercing:, which converts the less general operand (generality: integers 10 and 20, fractions 30, floats 40)."
Class {
	#name : #Number,
	#superclass : #Magnitude,
	#category : #'Kernel-Numbers'
}

{ #category : #arithmetic }
Number >> + aNumber [
	^ self subclassResponsibility
]

{ #category : #arithmetic }
Number >> - aNumber [
	^ self subclassResponsibility
]

{ #category : #arithmetic }
Number >> * aNumber [
	^ self subclassResponsibility
]

{ #category : #arithmetic }
Number >> / aNumber [
	^ self subclassResponsibility
]

{ #category : #arithmetic }
Number >> // aNumber [
	^ (self / aNumber) floor
]

{ #category : #arithmetic }
Number >> \\ aNumber [
	^ self - (self // aNumber * aNumber)
]

{ #category : #arithmetic }
Number >> quo: aNumber [
	^ (self / aNumber) truncated
]

{ #category : #arithmetic }
Number >> rem: aNumber [
	^ self - ((self quo: aNumber) * aNumber)
]

{ #category : #arithmetic }
Number >> abs [
	^ self negative ifTrue: [self negated] ifFalse: [self]
]

{ #category : #arithmetic }
Number >> negated [
	^ 0 - self
]

{ #category : #arithmetic }
Number >> reciprocal [
	^ 1 / self
]

{ #category : #arithmetic }
Number >> squared [
	^ self * self
]

{ #category : #arithmetic }
Number >> raisedTo: anInteger [
	"An integer power, by squaring."
	| result base n |
	anInteger isInteger ifFalse: [^ self error: 'raisedTo: takes an integer in 8b'].
	anInteger < 0 ifTrue: [^ (self raisedTo: anInteger negated) reciprocal].
	result := 1. base := self. n := anInteger.
	[n > 0] whileTrue: [
		n odd ifTrue: [result := result * base].
		base := base * base.
		n := n // 2].
	^ result
]

{ #category : #coercion }
Number >> generality [
	^ self subclassResponsibility
]

{ #category : #coercion }
Number >> coerce: aNumber [
	^ self subclassResponsibility
]

{ #category : #coercion }
Number >> retry: aSelector coercing: aNumber [
	aNumber isNumber ifFalse: [
		aSelector == #= ifTrue: [^ false].
		aSelector == #~= ifTrue: [^ true].
		^ self error: aNumber printString , ' is not a number'].
	self generality < aNumber generality ifTrue: [^ (aNumber coerce: self) perform: aSelector with: aNumber].
	self generality > aNumber generality ifTrue: [^ self perform: aSelector with: (self coerce: aNumber)].
	^ self error: 'cannot ' , aSelector , ' ' , self printString , ' and ' , aNumber printString
]

{ #category : #coercion }
Number >> asFloat [
	^ self subclassResponsibility
]

{ #category : #coercion }
Number >> asInteger [
	^ self truncated
]

{ #category : #coercion }
Number >> asNumber [
	^ self
]

{ #category : #truncation }
Number >> truncated [
	^ self subclassResponsibility
]

{ #category : #truncation }
Number >> rounded [
	^ (self + (self sign / 2)) truncated
]

{ #category : #truncation }
Number >> floor [
	| t |
	t := self truncated.
	^ (self < 0 and: [t ~= self]) ifTrue: [t - 1] ifFalse: [t]
]

{ #category : #truncation }
Number >> ceiling [
	| t |
	t := self truncated.
	^ (self > 0 and: [t ~= self]) ifTrue: [t + 1] ifFalse: [t]
]

{ #category : #testing }
Number >> isNumber [
	^ true
]

{ #category : #testing }
Number >> isZero [
	^ self = 0
]

{ #category : #testing }
Number >> negative [
	^ self < 0
]

{ #category : #testing }
Number >> positive [
	^ self >= 0
]

{ #category : #testing }
Number >> strictlyPositive [
	^ self > 0
]

{ #category : #testing }
Number >> sign [
	self > 0 ifTrue: [^ 1].
	self < 0 ifTrue: [^ -1].
	^ 0
]

{ #category : #testing }
Number >> even [
	^ self \\ 2 = 0
]

{ #category : #testing }
Number >> odd [
	^ self even not
]

{ #category : #testing }
Number >> isLiteral [
	^ true
]

{ #category : #intervals }
Number >> to: stop [
	^ Interval from: self to: stop
]

{ #category : #intervals }
Number >> to: stop by: step [
	^ Interval from: self to: stop by: step
]

{ #category : #intervals }
Number >> to: stop do: aBlock [
	| i |
	i := self.
	[i <= stop] whileTrue: [aBlock value: i. i := i + 1]
]

{ #category : #intervals }
Number >> to: stop by: step do: aBlock [
	| i |
	step = 0 ifTrue: [^ self error: 'step must not be zero'].
	i := self.
	step > 0
		ifTrue: [[i <= stop] whileTrue: [aBlock value: i. i := i + step]]
		ifFalse: [[i >= stop] whileTrue: [aBlock value: i. i := i + step]]
]

{ #category : #printing }
Number >> printOn: aStream [
	aStream nextPutAll: self printString
]

{ #category : #printing }
Number >> displayString [
	^ self printString
]

{ #category : #printing }
Number >> shallowCopy [
	^ self
]
