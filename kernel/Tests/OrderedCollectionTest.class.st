Class {
	#name : #OrderedCollectionTest,
	#superclass : #TestCase
}

{ #category : #accessing }
OrderedCollectionTest >> testADequeAtTheFrontKeepsABoundedArray [
	"The third review's small fixes, item 3: addFirst: with removeLast, ten held and 20 000 passed through, keeps an array of a few dozen slots (on 0b33ed3 grow doubled whenever the front was reached: 32 768)."
	| c |
	c := OrderedCollection new.
	1 to: 10 do: [:i | c addFirst: i].
	1 to: 20000 do: [:i | c addFirst: i. c removeLast].
	self assert: c size equals: 10.
	self assert: c asArray equals: (20000 to: 19991 by: -1) asArray.
	self assert: (c instVarAt: 1) size <= 64 description: 'the array has ' , (c instVarAt: 1) size printString , ' slots'
]

{ #category : #accessing }
OrderedCollectionTest >> testAQueueKeepsABoundedArray [
	"The third review's small fixes, item 3: addLast: with removeFirst, ten held and 20 000 passed through, keeps an array of a few dozen slots (on 0b33ed3 grow doubled whenever the end was reached: 32 768)."
	| c |
	c := OrderedCollection new.
	1 to: 10 do: [:i | c addLast: i].
	1 to: 20000 do: [:i | c addLast: i. c removeFirst].
	self assert: c size equals: 10.
	self assert: c asArray equals: (19991 to: 20000) asArray.
	self assert: (c instVarAt: 1) size <= 64 description: 'the array has ' , (c instVarAt: 1) size printString , ' slots'
]

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
OrderedCollectionTest >> testContentsStayRightAcrossEveryRecentre [
	"The third review's small fixes, item 3: a seeded mix of addFirst:, addLast:, removeFirst and removeLast against an Array kept beside it; the contents agree after every operation and the array stays bounded by the most the collection held (on 0b33ed3 the drift grew it past that bound)."
	| c model seed most |
	c := OrderedCollection new.
	model := #().
	seed := 16r5EED.
	most := 0.
	1 to: 6000 do: [:i | | op |
		seed := seed * 1103515245 + 12345 \\ 2147483648.
		"Twice as many addLast: as addFirst: and removeFirst as removeLast, so both ends drift towards the array's end as a queue's do; adds only when empty, removes only at 40."
		op := #(0 0 1 2 2 3) at: seed // 65536 \\ 6 + 1.
		model isEmpty ifTrue: [op := op \\ 2].
		model size >= 40 ifTrue: [op := op \\ 2 + 2].
		op = 0 ifTrue: [c addLast: i. model := model copyWith: i].
		op = 1 ifTrue: [c addFirst: i. model := (Array with: i) , model].
		op = 2 ifTrue: [self assert: c removeFirst equals: model first. model := model copyFrom: 2 to: model size].
		op = 3 ifTrue: [self assert: c removeLast equals: model last. model := model copyFrom: 1 to: model size - 1].
		most := most max: model size.
		self assert: c asArray equals: model].
	self assert: (c instVarAt: 1) size <= (8 max: most * 4) description: 'the array has ' , (c instVarAt: 1) size printString , ' slots for at most ' , most printString
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
