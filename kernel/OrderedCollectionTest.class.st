Class {
	#name : #OrderedCollectionTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
OrderedCollectionTest >> testAddingAndRemoving [
	| c |
	c := OrderedCollection new.
	1 to: 100 do: [:i | c add: i].
	self assert: c size = 100.
	self assert: c first = 1.
	self assert: c last = 100.
	c addFirst: 0.
	self assert: c first = 0.
	self assert: c removeFirst = 0.
	self assert: c removeLast = 100.
	self assert: c size = 99.
	c remove: 50.
	self assert: (c includes: 50) not.
	self assert: c size = 98.
	self should: [c remove: 500] raise: NotFound.
	c add: 7 beforeIndex: 1.
	self assert: c first = 7
]

{ #category : #accessing }
OrderedCollectionTest >> testEnumeration [
	| c |
	c := OrderedCollection withAll: #(1 2 3 4).
	self assert: (c collect: [:x | x * 10]) asArray = #(10 20 30 40).
	self assert: (c select: [:x | x > 2]) asArray = #(3 4).
	self assert: (c inject: 0 into: [:a :b | a + b]) = 10.
	self assert: c reversed asArray = #(4 3 2 1).
	self assert: (c copyFrom: 2 to: 3) asArray = #(2 3).
	self assert: (c , #(5)) asArray = #(1 2 3 4 5)
]

{ #category : #accessing }
OrderedCollectionTest >> testGrowingAtTheFront [
	| c |
	c := OrderedCollection new.
	1 to: 50 do: [:i | c addFirst: i].
	self assert: c first = 50.
	self assert: c last = 1.
	self assert: c asArray = (50 to: 1 by: -1) asArray
]

{ #category : #accessing }
OrderedCollectionTest >> testIndexing [
	| c |
	c := OrderedCollection withAll: #(1 2 3).
	self assert: (c at: 2) = 2.
	c at: 2 put: 9.
	self assert: (c at: 2) = 9.
	self should: [c at: 4] raise: SubscriptOutOfBounds
]
