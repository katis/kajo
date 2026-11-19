"The protocol every collection has, written on do:. Kernel collections are not synchronized (ADR 0009 section 12): share them between Processes through a Mutex, a Monitor or a SharedQueue."
Class {
	#name : #Collection,
	#superclass : #Object,
	#typeParameters : [
		'E'
	]
}

{ #category : #'adding and removing' }
Collection >> add: anObject <E> ^<E> [
	^ self subclassResponsibility
]

{ #category : #'adding and removing' }
Collection >> addAll: aCollection <Collection[E]> ^<Collection[E]> [
	aCollection do: [:e | self add: e].
	^ aCollection
]

{ #category : #'adding and removing' }
Collection >> remove: anObject <E> ^<E> [
	^ self remove: anObject ifAbsent: [NotFound new signal: anObject printString , ' not found']
]

{ #category : #'adding and removing' }
Collection >> remove: anObject <E> ifAbsent: aBlock <[^:X]> ^<E | X> [
	^ self subclassResponsibility
]

{ #category : #'adding and removing' }
Collection >> removeAll: aCollection <Collection[E]> ^<Collection[E]> [
	aCollection do: [:e | self remove: e].
	^ aCollection
]

{ #category : #converting }
Collection >> asArray ^<Array[E]> [
	| a i |
	a := Array new: self size.
	i := 0.
	self do: [:e | a at: (i := i + 1) put: e].
	^ a
]

{ #category : #converting }
Collection >> asIdentitySet ^<IdentitySet[E]> [
	^ IdentitySet new addAll: self; yourself
]

{ #category : #converting }
Collection >> asOrderedCollection ^<OrderedCollection[E]> [
	^ OrderedCollection new addAll: self; yourself
]

{ #category : #converting }
Collection >> asSet ^<Set[E]> [
	^ Set new addAll: self; yourself
]

{ #category : #converting }
Collection >> sorted ^<Array[E]> [
	^ self asArray copy sort
]

{ #category : #converting }
Collection >> sorted: aBlock <[E, E, ^Boolean]> ^<Array[E]> [
	^ self asArray copy sort: aBlock
]

{ #category : #converting }
Collection >> species ^<Self class> [
	^ self class
]

{ #category : #enumerating }
Collection >> allSatisfy: aBlock <[E, ^Boolean]> ^<Boolean> [
	self do: [:e | (aBlock value: e) ifFalse: [^ false]].
	^ true
]

{ #category : #enumerating }
Collection >> anyOne ^<E> [
	self do: [:e | ^ e].
	^ self error: 'the collection is empty'
]

{ #category : #enumerating }
Collection >> anySatisfy: aBlock <[E, ^Boolean]> ^<Boolean> [
	self do: [:e | (aBlock value: e) ifTrue: [^ true]].
	^ false
]

{ #category : #enumerating }
Collection >> collect: aBlock <[E, ^:X]> ^<Collection[X]> [
	| out |
	out := OrderedCollection new.
	self do: [:e | out add: (aBlock value: e)].
	^ out
]

{ #category : #enumerating }
Collection >> count: aBlock <[E, ^Boolean]> ^<Integer> [
	| n |
	n := 0.
	self do: [:e | (aBlock value: e) ifTrue: [n := n + 1]].
	^ n
]

{ #category : #enumerating }
Collection >> detect: aBlock <[E, ^Boolean]> ^<E> [
	^ self detect: aBlock ifNone: [NotFound new signal: 'no element satisfies the block']
]

{ #category : #enumerating }
Collection >> detect: aBlock <[E, ^Boolean]> ifNone: noneBlock <[^:X]> ^<E | X> [
	self do: [:e | (aBlock value: e) ifTrue: [^ e]].
	^ noneBlock value
]

{ #category : #enumerating }
Collection >> detectMax: aBlock <[E, ^Magnitude]> ^<E | Nil> [
	| best bestValue |
	self do: [:e | | v | v := aBlock value: e. (best isNil or: [v > bestValue]) ifTrue: [best := e. bestValue := v]].
	^ best
]

{ #category : #enumerating }
Collection >> detectMin: aBlock <[E, ^Magnitude]> ^<E | Nil> [
	| best bestValue |
	self do: [:e | | v | v := aBlock value: e. (best isNil or: [v < bestValue]) ifTrue: [best := e. bestValue := v]].
	^ best
]

{ #category : #enumerating }
Collection >> do: aBlock <[E, ^Dynamic]> ^<Self> [
	^ self subclassResponsibility
]

{ #category : #enumerating }
Collection >> do: aBlock <[E, ^Dynamic]> separatedBy: separatorBlock <[^Dynamic]> ^<Self> [
	| first |
	first := true.
	self do: [:e | first ifFalse: [separatorBlock value]. first := false. aBlock value: e]
]

{ #category : #enumerating }
Collection >> inject: initial <:A> into: aBlock <[A, E, ^A]> ^<A> [
	| acc |
	acc := initial.
	self do: [:e | acc := aBlock value: acc value: e].
	^ acc
]

{ #category : #enumerating }
Collection >> max ^<E> [
	^ self inject: self anyOne into: [:a :b | a max: b]
]

{ #category : #enumerating }
Collection >> min ^<E> [
	^ self inject: self anyOne into: [:a :b | a min: b]
]

{ #category : #enumerating }
Collection >> noneSatisfy: aBlock <[E, ^Boolean]> ^<Boolean> [
	^ (self anySatisfy: aBlock) not
]

{ #category : #enumerating }
Collection >> reject: aBlock <[E, ^Boolean]> ^<Self> [
	^ self select: [:e | (aBlock value: e) not]
]

{ #category : #enumerating }
Collection >> select: aBlock <[E, ^Boolean]> ^<Self> [
	| out |
	out := self species new.
	self do: [:e | (aBlock value: e) ifTrue: [out add: e]].
	^ out
]

{ #category : #enumerating }
Collection >> sum ^<Dynamic> [
	^ self inject: 0 into: [:a :b | a + b]
]

{ #category : #enumerating }
Collection >> sum: aBlock <[E, ^Number]> ^<Number> [
	^ self inject: 0 into: [:a :b | a + (aBlock value: b)]
]

{ #category : #printing }
Collection >> displayString ^<String> [
	| s |
	s := WriteStream on: String new.
	s nextPutAll: self class name; nextPutAll: ' ('.
	self do: [:e | s nextPutAll: e displayString] separatedBy: [s space].
	s nextPut: $).
	^ s contents
]

{ #category : #printing }
Collection >> printOn: aStream <WriteStream> ^<Self> [
	aStream nextPutAll: self class name; nextPutAll: ' ('.
	self do: [:e | aStream print: e] separatedBy: [aStream space].
	aStream nextPut: $)
]

{ #category : #testing }
Collection >> identityIncludes: anObject <Object> ^<Boolean> [
	^ self anySatisfy: [:e | e == anObject]
]

{ #category : #testing }
Collection >> ifEmpty: aBlock <[^:X]> ^<Self | X> [
	^ self isEmpty ifTrue: [aBlock value] ifFalse: [self]
]

{ #category : #testing }
Collection >> ifNotEmpty: aBlock <[Self, ^:X]> ^<Self | X> [
	^ self isEmpty ifTrue: [self] ifFalse: [aBlock cull: self]
]

{ #category : #testing }
Collection >> includes: anObject <Object> ^<Boolean> [
	^ self anySatisfy: [:e | e = anObject]
]

{ #category : #testing }
Collection >> isCollection ^<Boolean> [
	^ true
]

{ #category : #testing }
Collection >> isEmpty ^<Boolean> [
	^ self size = 0
]

{ #category : #testing }
Collection >> isEmptyOrNil ^<Boolean> [
	^ self isEmpty
]

{ #category : #testing }
Collection >> isNotEmpty ^<Boolean> [
	^ self notEmpty
]

{ #category : #testing }
Collection >> notEmpty ^<Boolean> [
	^ self isEmpty not
]

{ #category : #testing }
Collection >> occurrencesOf: anObject <Object> ^<Integer> [
	^ self count: [:e | e = anObject]
]

{ #category : #testing }
Collection >> size ^<Integer> [
	| n |
	n := 0.
	self do: [:e | n := n + 1].
	^ n
]
