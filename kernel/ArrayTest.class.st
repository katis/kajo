Class {
	#name : #ArrayTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
ArrayTest >> testBasics [
	| a |
	a := Array new: 3.
	self assert: a size = 3.
	self assert: (a at: 1) isNil.
	a at: 2 put: 5.
	self assert: (a at: 2) = 5.
	self should: [a at: 4] raise: SubscriptOutOfBounds.
	self should: [a at: 0 put: 1] raise: SubscriptOutOfBounds.
	self assert: (Array with: 1 with: 2 with: 3) = #(1 2 3).
	self assert: {1 + 1. 'x'} = #(2 'x').
	self assert: (Array new: 2 withAll: 7) = #(7 7)
]

{ #category : #accessing }
ArrayTest >> testEnumeration [
	self assert: (#(1 2 3) collect: [:x | x * x]) = #(1 4 9).
	self assert: (#(1 2 3 4) select: [:x | x even]) = #(2 4).
	self assert: (#(1 2 3 4) reject: [:x | x even]) = #(1 3).
	self assert: (#(1 2 3) inject: 0 into: [:a :b | a + b]) = 6.
	self assert: (#(1 2 3) detect: [:x | x > 1]) = 2.
	self assert: (#(1 2 3) detect: [:x | x > 5] ifNone: [0]) = 0.
	self assert: (#(1 2 3) anySatisfy: [:x | x > 2]).
	self assert: (#(1 2 3) allSatisfy: [:x | x > 0]).
	self assert: (#(1 2 3) count: [:x | x odd]) = 2.
	self assert: #(3 1 2) max = 3.
	self assert: #(1 2 3) sum = 6.
	self assert: (#(1 2 3) with: #(4 5 6) collect: [:a :b | a + b]) = #(5 7 9)
]

{ #category : #accessing }
ArrayTest >> testCopying [
	self assert: (#(1 2 3 4) copyFrom: 2 to: 3) = #(2 3).
	self assert: #(1 2) , #(3) = #(1 2 3).
	self assert: #(1 2 3) reversed = #(3 2 1).
	self assert: (#(1 2) copyWith: 3) = #(1 2 3).
	self assert: #(1 2 3) allButFirst = #(2 3).
	self assert: (#(1 2 3) indexOf: 3) = 3.
	self assert: (#(1 2 3) indexOf: 4) = 0
]

{ #category : #accessing }
ArrayTest >> testSorting [
	self assert: #(3 1 2) sorted = #(1 2 3).
	self assert: (#(3 1 2) sorted: [:a :b | a >= b]) = #(3 2 1).
	self assert: (#('pear' 'apple' 'fig') sorted: [:a :b | a <= b]) = #('apple' 'fig' 'pear')
]

{ #category : #accessing }
ArrayTest >> testEquality [
	self assert: #(1 2) = #(1 2).
	self deny: #(1 2) = #(1 3).
	self deny: #(1 2) = (OrderedCollection with: 1 with: 2).
	self assert: #(1 2) hash = #(1 2) hash
]

{ #category : #accessing }
ArrayTest >> testByteArray [
	| b |
	b := ByteArray new: 3.
	b at: 1 put: 255.
	self assert: (b at: 1) = 255.
	self should: [b at: 1 put: 256] raise: Error.
	self assert: #[1 2 3] size = 3.
	self assert: #[1 2 3] printString = '#[1 2 3]'
]
