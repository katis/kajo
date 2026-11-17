"The number tower: SmallInteger, LargePositiveInteger and LargeNegativeInteger, Fraction, Float and SmallFloat. A primitive that cannot answer for a mixed pair falls back to retry:coercing:, which converts the less general operand (generality: integers 10 and 20, fractions 30, floats 40)."
Class {
	#name : #Number,
	#superclass : #Magnitude
}

{ #category : #arithmetic }
Number >> * aNumber <Number> ^<Number> [
	^ self subclassResponsibility
]

{ #category : #arithmetic }
Number >> + aNumber <Number> ^<Number> [
	^ self subclassResponsibility
]

{ #category : #arithmetic }
Number >> - aNumber <Number> ^<Number> [
	^ self subclassResponsibility
]

{ #category : #arithmetic }
Number >> / aNumber <Number> ^<Number> [
	^ self subclassResponsibility
]

{ #category : #arithmetic }
Number >> // aNumber <Number> ^<Integer> [
	^ (self / aNumber) floor
]

{ #category : #arithmetic }
Number >> \\ aNumber <Number> ^<Number> [
	^ self - (self // aNumber * aNumber)
]

{ #category : #arithmetic }
Number >> abs ^<Number> [
	^ self negative ifTrue: [self negated] ifFalse: [self]
]

{ #category : #arithmetic }
Number >> negated ^<Number> [
	^ 0 - self
]

{ #category : #arithmetic }
Number >> quo: aNumber <Number> ^<Integer> [
	^ (self / aNumber) truncated
]

{ #category : #arithmetic }
Number >> raisedTo: anInteger <Integer> ^<Number> [
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

{ #category : #arithmetic }
Number >> reciprocal ^<Number> [
	^ 1 / self
]

{ #category : #arithmetic }
Number >> rem: aNumber <Number> ^<Number> [
	^ self - ((self quo: aNumber) * aNumber)
]

{ #category : #arithmetic }
Number >> squared ^<Number> [
	^ self * self
]

{ #category : #coercion }
Number >> asFloat ^<Float> [
	^ self subclassResponsibility
]

{ #category : #coercion }
Number >> asInteger ^<Integer> [
	^ self truncated
]

{ #category : #coercion }
Number >> asNumber ^<Self> [
	^ self
]

{ #category : #coercion }
Number >> coerce: aNumber <Number> ^<Number> [
	^ self subclassResponsibility
]

{ #category : #coercion }
Number >> generality ^<Integer> [
	^ self subclassResponsibility
]

{ #category : #coercion }
Number >> retry: aSelector <Symbol> coercing: aNumber <Object> ^<Dynamic> [
	aNumber isNumber ifFalse: [
		aSelector == #= ifTrue: [^ false].
		aSelector == #~= ifTrue: [^ true].
		^ self error: aNumber printString , ' is not a number'].
	self generality < aNumber generality ifTrue: [^ (aNumber coerce: self) perform: aSelector with: aNumber].
	self generality > aNumber generality ifTrue: [^ self perform: aSelector with: (self coerce: aNumber)].
	^ self error: 'cannot ' , aSelector , ' ' , self printString , ' and ' , aNumber printString
]

{ #category : #intervals }
Number >> to: stop <Number> ^<Interval[Self]> [
	^ Interval from: self to: stop
]

{ #category : #intervals }
Number >> to: stop <Number> by: step <Number> ^<Interval[Number]> [
	^ Interval from: self to: stop by: step
]

{ #category : #intervals }
Number >> to: stop <Number> by: step <Number> do: aBlock <[Self, ^Dynamic]> ^<Self> [
	| i |
	step = 0 ifTrue: [^ self error: 'step must not be zero'].
	i := self.
	step > 0
		ifTrue: [[i <= stop] whileTrue: [aBlock value: i. i := i + step]]
		ifFalse: [[i >= stop] whileTrue: [aBlock value: i. i := i + step]]
]

{ #category : #intervals }
Number >> to: stop <Number> do: aBlock <[Self, ^Dynamic]> ^<Self> [
	| i |
	i := self.
	[i <= stop] whileTrue: [aBlock value: i. i := i + 1]
]

{ #category : #printing }
Number >> displayString ^<String> [
	^ self printString
]

{ #category : #printing }
Number >> printOn: aStream <WriteStream> ^<Self> [
	aStream nextPutAll: self printString
]

{ #category : #printing }
Number >> shallowCopy ^<Self> [
	^ self
]

{ #category : #testing }
Number >> even ^<Boolean> [
	^ self \\ 2 = 0
]

{ #category : #testing }
Number >> isLiteral [
	^ true
]

{ #category : #testing }
Number >> isNumber [
	^ true
]

{ #category : #testing }
Number >> isZero ^<Boolean> [
	^ self = 0
]

{ #category : #testing }
Number >> negative ^<Boolean> [
	^ self < 0
]

{ #category : #testing }
Number >> odd ^<Boolean> [
	^ self even not
]

{ #category : #testing }
Number >> positive ^<Boolean> [
	^ self >= 0
]

{ #category : #testing }
Number >> sign ^<Integer> [
	self > 0 ifTrue: [^ 1].
	self < 0 ifTrue: [^ -1].
	^ 0
]

{ #category : #testing }
Number >> strictlyPositive ^<Boolean> [
	^ self > 0
]

{ #category : #truncation }
Number >> ceiling ^<Integer> [
	| t |
	t := self truncated.
	^ (self > 0 and: [t ~= self]) ifTrue: [t + 1] ifFalse: [t]
]

{ #category : #truncation }
Number >> floor ^<Integer> [
	| t |
	t := self truncated.
	^ (self < 0 and: [t ~= self]) ifTrue: [t - 1] ifFalse: [t]
]

{ #category : #truncation }
Number >> rounded ^<Integer> [
	^ (self + (self sign / 2)) truncated
]

{ #category : #truncation }
Number >> truncated ^<Integer> [
	^ self subclassResponsibility
]
