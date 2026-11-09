"Exact division keeps the number tower honest."
Class {
	#name : #FractionTest,
	#superclass : #TestCase
}

{ #category : #accessing }
FractionTest >> testArithmetic [
	self assert: (1 / 2) + (1 / 3) = (5 / 6).
	self assert: (1 / 2) - (1 / 3) = (1 / 6).
	self assert: (2 / 3) * (3 / 4) = (1 / 2).
	self assert: (1 / 2) / (1 / 4) = 2.
	self assert: (1 / 2) + 1 = (3 / 2).
	self assert: 1 + (1 / 2) = (3 / 2).
	self assert: (1 / 3) reciprocal = 3.
	self assert: (1 / 2) < (2 / 3).
	self assert: (3 / 2) > 1.
	self assert: (7 / 2) truncated = 3.
	self assert: (-7 / 2) floor = -4
]

{ #category : #accessing }
FractionTest >> testCreation [
	self assert: (1 / 2) class == Fraction.
	self assert: (2 / 4) = (1 / 2).
	self assert: (4 / 2) class == SmallInteger.
	self assert: (1 / -2) numerator = -1.
	self assert: (1 / -2) denominator = 2
]

{ #category : #accessing }
FractionTest >> testFloats [
	self assert: (1 / 2) asFloat = 0.5.
	self assert: (1 / 2) + 0.5 = 1.0.
	self assert: 0.75 asFraction = (3 / 4)
]

{ #category : #accessing }
FractionTest >> testPrinting [
	self assert: (3 / 4) printString = '3/4'
]
