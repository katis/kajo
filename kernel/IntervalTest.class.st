Class {
	#name : #IntervalTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
IntervalTest >> testIntervals [
	self assert: (1 to: 5) size = 5.
	self assert: (1 to: 0) size = 0.
	self assert: (1 to: 10 by: 3) asArray = #(1 4 7 10).
	self assert: (10 to: 1 by: -4) asArray = #(10 6 2).
	self assert: ((1 to: 5) collect: [:x | x * 2]) = #(2 4 6 8 10).
	self assert: ((1 to: 5) select: [:x | x odd]) = #(1 3 5).
	self assert: ((1 to: 5) inject: 0 into: [:a :b | a + b]) = 15.
	self assert: (1 to: 5) printString = '(1 to: 5)'.
	self assert: ((1 to: 3) at: 2) = 2
]
