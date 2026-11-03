"The protocol every collection has, written on do:. Kernel collections are not synchronized (ADR 0009 section 12): share them between Processes through a Mutex, a Monitor or a SharedQueue."
Class {
	#name : #Collection,
	#superclass : #Object,
	#category : #'Kernel-Collections'
}

{ #category : #enumerating }
Collection >> do: aBlock [
	^ self subclassResponsibility
]

{ #category : #enumerating }
Collection >> do: aBlock separatedBy: separatorBlock [
	| first |
	first := true.
	self do: [:e | first ifFalse: [separatorBlock value]. first := false. aBlock value: e]
]

{ #category : #enumerating }
Collection >> collect: aBlock [
	| out |
	out := OrderedCollection new.
	self do: [:e | out add: (aBlock value: e)].
	^ out
]

{ #category : #enumerating }
Collection >> select: aBlock [
	| out |
	out := self species new.
	self do: [:e | (aBlock value: e) ifTrue: [out add: e]].
	^ out
]

{ #category : #enumerating }
Collection >> reject: aBlock [
	^ self select: [:e | (aBlock value: e) not]
]

{ #category : #enumerating }
Collection >> detect: aBlock [
	^ self detect: aBlock ifNone: [NotFound new signal: 'no element satisfies the block']
]

{ #category : #enumerating }
Collection >> detect: aBlock ifNone: noneBlock [
	self do: [:e | (aBlock value: e) ifTrue: [^ e]].
	^ noneBlock value
]

{ #category : #enumerating }
Collection >> inject: initial into: aBlock [
	| acc |
	acc := initial.
	self do: [:e | acc := aBlock value: acc value: e].
	^ acc
]

{ #category : #enumerating }
Collection >> anySatisfy: aBlock [
	self do: [:e | (aBlock value: e) ifTrue: [^ true]].
	^ false
]

{ #category : #enumerating }
Collection >> allSatisfy: aBlock [
	self do: [:e | (aBlock value: e) ifFalse: [^ false]].
	^ true
]

{ #category : #enumerating }
Collection >> noneSatisfy: aBlock [
	^ (self anySatisfy: aBlock) not
]

{ #category : #enumerating }
Collection >> count: aBlock [
	| n |
	n := 0.
	self do: [:e | (aBlock value: e) ifTrue: [n := n + 1]].
	^ n
]

{ #category : #enumerating }
Collection >> sum [
	^ self inject: 0 into: [:a :b | a + b]
]

{ #category : #enumerating }
Collection >> sum: aBlock [
	^ self inject: 0 into: [:a :b | a + (aBlock value: b)]
]

{ #category : #enumerating }
Collection >> max [
	^ self inject: self anyOne into: [:a :b | a max: b]
]

{ #category : #enumerating }
Collection >> min [
	^ self inject: self anyOne into: [:a :b | a min: b]
]

{ #category : #enumerating }
Collection >> detectMax: aBlock [
	| best bestValue |
	self do: [:e | | v | v := aBlock value: e. (best isNil or: [v > bestValue]) ifTrue: [best := e. bestValue := v]].
	^ best
]

{ #category : #enumerating }
Collection >> detectMin: aBlock [
	| best bestValue |
	self do: [:e | | v | v := aBlock value: e. (best isNil or: [v < bestValue]) ifTrue: [best := e. bestValue := v]].
	^ best
]

{ #category : #enumerating }
Collection >> anyOne [
	self do: [:e | ^ e].
	^ self error: 'the collection is empty'
]

{ #category : #testing }
Collection >> size [
	| n |
	n := 0.
	self do: [:e | n := n + 1].
	^ n
]

{ #category : #testing }
Collection >> isEmpty [
	^ self size = 0
]

{ #category : #testing }
Collection >> notEmpty [
	^ self isEmpty not
]

{ #category : #testing }
Collection >> isNotEmpty [
	^ self notEmpty
]

{ #category : #testing }
Collection >> isEmptyOrNil [
	^ self isEmpty
]

{ #category : #testing }
Collection >> ifEmpty: aBlock [
	^ self isEmpty ifTrue: [aBlock value] ifFalse: [self]
]

{ #category : #testing }
Collection >> ifNotEmpty: aBlock [
	^ self isEmpty ifTrue: [self] ifFalse: [aBlock cull: self]
]

{ #category : #testing }
Collection >> includes: anObject [
	^ self anySatisfy: [:e | e = anObject]
]

{ #category : #testing }
Collection >> identityIncludes: anObject [
	^ self anySatisfy: [:e | e == anObject]
]

{ #category : #testing }
Collection >> occurrencesOf: anObject [
	^ self count: [:e | e = anObject]
]

{ #category : #testing }
Collection >> isCollection [
	^ true
]

{ #category : #'adding and removing' }
Collection >> add: anObject [
	^ self subclassResponsibility
]

{ #category : #'adding and removing' }
Collection >> addAll: aCollection [
	aCollection do: [:e | self add: e].
	^ aCollection
]

{ #category : #'adding and removing' }
Collection >> remove: anObject [
	^ self remove: anObject ifAbsent: [NotFound new signal: anObject printString , ' not found']
]

{ #category : #'adding and removing' }
Collection >> remove: anObject ifAbsent: aBlock [
	^ self subclassResponsibility
]

{ #category : #'adding and removing' }
Collection >> removeAll: aCollection [
	aCollection do: [:e | self remove: e].
	^ aCollection
]

{ #category : #converting }
Collection >> asArray [
	| a i |
	a := Array new: self size.
	i := 0.
	self do: [:e | a at: (i := i + 1) put: e].
	^ a
]

{ #category : #converting }
Collection >> asOrderedCollection [
	^ OrderedCollection new addAll: self; yourself
]

{ #category : #converting }
Collection >> asSet [
	^ Set new addAll: self; yourself
]

{ #category : #converting }
Collection >> asIdentitySet [
	^ IdentitySet new addAll: self; yourself
]

{ #category : #converting }
Collection >> sorted [
	^ self asArray copy sort
]

{ #category : #converting }
Collection >> sorted: aBlock [
	^ self asArray copy sort: aBlock
]

{ #category : #converting }
Collection >> species [
	^ self class
]

{ #category : #printing }
Collection >> printOn: aStream [
	aStream nextPutAll: self class name; nextPutAll: ' ('.
	self do: [:e | aStream print: e] separatedBy: [aStream space].
	aStream nextPut: $)
]

{ #category : #printing }
Collection >> displayString [
	| s |
	s := WriteStream on: String new.
	s nextPutAll: self class name; nextPutAll: ' ('.
	self do: [:e | s nextPutAll: e displayString] separatedBy: [s space].
	s nextPut: $).
	^ s contents
]
