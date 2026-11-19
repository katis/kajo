"A growable sequence: adds and removes at both ends in constant time (amortized)."
Class {
	#name : #OrderedCollection,
	#superclass : #SequenceableCollection,
	#typeParameters : [
		'E'
	],
	#instVars : [
		'array <Array[E | Nil]>',
		'firstIndex <Integer>',
		'lastIndex <Integer>'
	]
}

{ #category : #accessing }
OrderedCollection >> , aCollection <Collection[E]> ^<Self> [
	^ self copy addAll: aCollection; yourself
]

{ #category : #accessing }
OrderedCollection >> add: anObject <E> ^<E> [
	^ self addLast: anObject
]

{ #category : #accessing }
OrderedCollection >> add: anObject <E> beforeIndex: index <Integer> ^<E> [
	self addLast: nil.
	self size to: index + 1 by: -1 do: [:i | self at: i put: (self at: i - 1)].
	^ self at: index put: anObject
]

{ #category : #accessing }
OrderedCollection >> addFirst: anObject <E> ^<E> [
	firstIndex = 1 ifTrue: [self grow].
	firstIndex := firstIndex - 1.
	^ array at: firstIndex put: anObject
]

{ #category : #accessing }
OrderedCollection >> addLast: anObject <E> ^<E> [
	lastIndex = array size ifTrue: [self grow].
	lastIndex := lastIndex + 1.
	^ array at: lastIndex put: anObject
]

{ #category : #accessing }
OrderedCollection >> asArray ^<Array[E]> [
	| a |
	a := Array new: self size.
	a replaceFrom: 1 to: self size with: array startingAt: firstIndex.
	^ a
]

{ #category : #accessing }
OrderedCollection >> at: index <Integer> ^<E> [
	(index isInteger and: [index between: 1 and: self size]) ifFalse: [^ self indexError: index].
	^ array at: firstIndex + index - 1
]

{ #category : #accessing }
OrderedCollection >> at: index <Integer> put: anObject <E> ^<E> [
	(index isInteger and: [index between: 1 and: self size]) ifFalse: [^ self indexError: index].
	^ array at: firstIndex + index - 1 put: anObject
]

{ #category : #accessing }
OrderedCollection >> collect: aBlock <[E, ^:X]> ^<OrderedCollection[X]> [
	| out |
	out := OrderedCollection new: self size.
	self do: [:e | out addLast: (aBlock value: e)].
	^ out
]

{ #category : #accessing }
OrderedCollection >> copyFrom: start <Integer> to: stop <Integer> ^<OrderedCollection[E]> [
	| out |
	out := OrderedCollection new: stop - start + 1.
	start to: stop do: [:i | out addLast: (self at: i)].
	^ out
]

{ #category : #accessing }
OrderedCollection >> copyWith: anObject <E> ^<Self> [
	^ self copy add: anObject; yourself
]

{ #category : #accessing }
OrderedCollection >> do: aBlock <[E, ^Dynamic]> ^<Self> [
	firstIndex to: lastIndex do: [:i | aBlock value: (array at: i)]
]

{ #category : #accessing }
OrderedCollection >> grow ^<Self> [
	| bigger n start |
	n := self size.
	bigger := Array new: (array size * 2 max: 8).
	start := bigger size - n // 2 + 1.
	bigger replaceFrom: start to: start + n - 1 with: array startingAt: firstIndex.
	array := bigger.
	firstIndex := start.
	lastIndex := start + n - 1
]

{ #category : #accessing }
OrderedCollection >> postCopy [
	array := array copy
]

{ #category : #accessing }
OrderedCollection >> remove: anObject <E> ifAbsent: aBlock <[^:X]> ^<E | X> [
	1 to: self size do: [:i | (self at: i) = anObject ifTrue: [^ self removeIndex: i]].
	^ aBlock value
]

{ #category : #accessing }
OrderedCollection >> removeAll ^<Self> [
	self setCapacity: 8
]

{ #category : #accessing }
OrderedCollection >> removeFirst ^<E> [
	| x |
	self isEmpty ifTrue: [^ self error: 'the collection is empty'].
	x := array at: firstIndex.
	array at: firstIndex put: nil.
	firstIndex := firstIndex + 1.
	^ x
]

{ #category : #accessing }
OrderedCollection >> removeFirst: n <Integer> ^<SequenceableCollection[E]> [
	^ (1 to: n) collect: [:i | self removeFirst]
]

{ #category : #accessing }
OrderedCollection >> removeIndex: index <Integer> ^<E> [
	| x |
	x := self at: index.
	index to: self size - 1 do: [:i | self at: i put: (self at: i + 1)].
	array at: lastIndex put: nil.
	lastIndex := lastIndex - 1.
	^ x
]

{ #category : #accessing }
OrderedCollection >> removeLast ^<E> [
	| x |
	self isEmpty ifTrue: [^ self error: 'the collection is empty'].
	x := array at: lastIndex.
	array at: lastIndex put: nil.
	lastIndex := lastIndex - 1.
	^ x
]

{ #category : #accessing }
OrderedCollection >> removeLast: n <Integer> ^<SequenceableCollection[E]> [
	^ ((1 to: n) collect: [:i | self removeLast]) reversed
]

{ #category : #accessing }
OrderedCollection >> reverseDo: aBlock <[E, ^Dynamic]> ^<Self> [
	lastIndex to: firstIndex by: -1 do: [:i | aBlock value: (array at: i)]
]

{ #category : #accessing }
OrderedCollection >> reversed ^<OrderedCollection[E]> [
	| out |
	out := OrderedCollection new: self size.
	self reverseDo: [:e | out addLast: e].
	^ out
]

{ #category : #accessing }
OrderedCollection >> select: aBlock <[E, ^Boolean]> ^<OrderedCollection[E]> [
	| out |
	out := OrderedCollection new.
	self do: [:e | (aBlock value: e) ifTrue: [out addLast: e]].
	^ out
]

{ #category : #accessing }
OrderedCollection >> setCapacity: n <Integer> ^<Self> [
	array := Array new: (n max: 2).
	firstIndex := array size // 4 + 1.
	lastIndex := firstIndex - 1
]

{ #category : #accessing }
OrderedCollection >> size ^<Integer> [
	^ lastIndex - firstIndex + 1
]

{ #category : #accessing }
OrderedCollection >> species ^<Self class> [
	^ OrderedCollection
]

{ #category : #accessing }
OrderedCollection class >> new ^<Instance> [
	^ self new: 8
]

{ #category : #accessing }
OrderedCollection class >> new: capacity <Integer> ^<Instance> [
	^ self basicNew setCapacity: capacity
]

{ #category : #accessing }
OrderedCollection class >> with: a <:X> ^<Instance[X]> [
	^ self new add: a; yourself
]

{ #category : #accessing }
OrderedCollection class >> with: a <:X> with: b <X> ^<Instance[X]> [
	^ self new add: a; add: b; yourself
]

{ #category : #accessing }
OrderedCollection class >> with: a <:X> with: b <X> with: c <X> ^<Instance[X]> [
	^ self new add: a; add: b; add: c; yourself
]

{ #category : #accessing }
OrderedCollection class >> withAll: aCollection <Collection[:X]> ^<Instance[X]> [
	^ self new addAll: aCollection; yourself
]
