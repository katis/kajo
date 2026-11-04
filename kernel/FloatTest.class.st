"SmallFloats, boxed Floats, IEEE arithmetic, printing."
Class {
	#name : #FloatTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
FloatTest >> testArithmetic [
	self assert: 1.5 + 2.25 = 3.75.
	self assert: 1.5 * 2 = 3.0.
	self assert: 3 + 0.5 = 3.5.
	self assert: 1.0 / 4 = 0.25.
	self assert: 2.0 sqrt * 2.0 sqrt - 2.0 < 1.0e-15.
	self assert: 1.5 < 2.
	self assert: 2 > 1.5.
	self assert: 1.0 = 1
]

{ #category : #accessing }
FloatTest >> testBoxedFloats [
	| big |
	big := 1.0e200.
	self assert: big * 2 / 2 = big.
	self assert: big > 1.0e199.
	self assert: (big * 0.0) = 0.0.
	self assert: Float infinity isInfinite.
	self assert: Float nan isNaN.
	self deny: Float nan = Float nan
]

{ #category : #accessing }
FloatTest >> testHashAgreesWithEquality [
	self assert: 2.0 hash = 2 hash.
	self assert: 2.0 = 2
]

{ #category : #accessing }
FloatTest >> testPrinting [
	self assert: 1.5 printString = '1.5'.
	self assert: 1.0 printString = '1.0'.
	self assert: 0.1 printString = '0.1'.
	self assert: 1.0e100 printString = '1.0e100'.
	self assert: -2.5e-7 printString = '-2.5e-7'.
	self assert: '3.25' asFloat = 3.25
]

{ #category : #accessing }
FloatTest >> testTruncation [
	self assert: 3.7 truncated = 3.
	self assert: -3.7 truncated = -3.
	self assert: 3.5 rounded = 4.
	self assert: -3.7 floor = -4.
	self assert: 3.2 ceiling = 4.
	self assert: 1.0e20 truncated = 100000000000000000000
]
