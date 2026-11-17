"Keys to values, by = and hash; the entries are Associations."
Class {
	#name : #Dictionary,
	#superclass : #HashedCollection,
	#typeParameters : [
		'K',
		'V'
	],
	#superclassType : 'HashedCollection[V]'
}

{ #category : #accessing }
Dictionary >> = aDictionary [
	self == aDictionary ifTrue: [^ true].
	(aDictionary isKindOf: Dictionary) ifFalse: [^ false].
	self size = aDictionary size ifFalse: [^ false].
	self keysAndValuesDo: [:k :v | (aDictionary at: k ifAbsent: [^ false]) = v ifFalse: [^ false]].
	^ true
]

{ #category : #accessing }
Dictionary >> add: anAssociation <Association[K, V]> ^<Association[K, V]> [
	self at: anAssociation key put: anAssociation value.
	^ anAssociation
]

{ #category : #accessing }
Dictionary >> associations ^<Array[Association[K, V]]> [
	| out |
	out := OrderedCollection new: self size.
	self associationsDo: [:a | out add: a].
	^ out asArray
]

{ #category : #accessing }
Dictionary >> associationsDo: aBlock <[Association[K, V], ^Dynamic]> ^<Self> [
	array do: [:a | a == nil ifFalse: [aBlock value: a]]
]

{ #category : #accessing }
Dictionary >> associationsDo: aBlock <[Association[K, V], ^Dynamic]> separatedBy: sepBlock <[^Dynamic]> ^<Self> [
	| first |
	first := true.
	self associationsDo: [:a | first ifFalse: [sepBlock value]. first := false. aBlock value: a]
]

{ #category : #accessing }
Dictionary >> at: key <K> ^<V> [
	^ self at: key ifAbsent: [KeyNotFound new key: key; signal: 'key not found: ' , key printString]
]

{ #category : #accessing }
Dictionary >> at: key <K> ifAbsent: aBlock <[^:X]> ^<V | X> [
	| a |
	key == nil ifTrue: [^ aBlock value].
	a := array at: (self indexFor: key).
	a == nil ifTrue: [^ aBlock value].
	^ a value
]

{ #category : #accessing }
Dictionary >> at: key <K> ifAbsentPut: aBlock <[^V]> ^<V> [
	^ self at: key ifAbsent: [self at: key put: aBlock value]
]

{ #category : #accessing }
Dictionary >> at: key <K> ifPresent: aBlock <[V, ^:X]> ^<X | Nil> [
	^ aBlock cull: (self at: key ifAbsent: [^ nil])
]

{ #category : #accessing }
Dictionary >> at: key <K> ifPresent: presentBlock <[V, ^:X]> ifAbsent: absentBlock <[^:Y]> ^<X | Y> [
	^ presentBlock cull: (self at: key ifAbsent: [^ absentBlock value])
]

{ #category : #accessing }
Dictionary >> at: key <K> put: value <V> ^<V> [
	| i a |
	key == nil ifTrue: [^ self error: 'a Dictionary key cannot be nil'].
	i := self indexFor: key.
	a := array at: i.
	a == nil
		ifTrue: [
			array at: i put: (Association key: key value: value).
			tally := tally + 1.
			self growIfNeeded]
		ifFalse: [a value: value].
	^ value
]

{ #category : #accessing }
Dictionary >> collect: aBlock <[V, ^:X]> ^<Dictionary[K, X]> [
	| out |
	out := self class new: self size.
	self keysAndValuesDo: [:k :v | out at: k put: (aBlock value: v)].
	^ out
]

{ #category : #accessing }
Dictionary >> do: aBlock <[V, ^Dynamic]> ^<Self> [
	self valuesDo: aBlock
]

{ #category : #accessing }
Dictionary >> hash [
	^ self size
]

{ #category : #accessing }
Dictionary >> includes: value <Object> ^<Boolean> [
	^ self anySatisfy: [:v | v = value]
]

{ #category : #accessing }
Dictionary >> includesKey: key <Object> ^<Boolean> [
	key == nil ifTrue: [^ false].
	^ (array at: (self indexFor: key)) notNil
]

{ #category : #accessing }
Dictionary >> keyAtValue: value <Object> ^<K | Nil> [
	^ self keyAtValue: value ifAbsent: [nil]
]

{ #category : #accessing }
Dictionary >> keyAtValue: value <Object> ifAbsent: aBlock <[^:X]> ^<K | X> [
	self keysAndValuesDo: [:k :v | v = value ifTrue: [^ k]].
	^ aBlock value
]

{ #category : #accessing }
Dictionary >> keyOf: entry <Association[K, V]> ^<K> [
	^ entry key
]

{ #category : #accessing }
Dictionary >> keys ^<Array[K]> [
	| out |
	out := OrderedCollection new: self size.
	self keysDo: [:k | out add: k].
	^ out asArray
]

{ #category : #accessing }
Dictionary >> keysAndValuesDo: aBlock <[K, V, ^Dynamic]> ^<Self> [
	self associationsDo: [:a | aBlock value: a key value: a value]
]

{ #category : #accessing }
Dictionary >> keysDo: aBlock <[K, ^Dynamic]> ^<Self> [
	self associationsDo: [:a | aBlock value: a key]
]

{ #category : #accessing }
Dictionary >> keysSortedSafely ^<Array[K]> [
	^ self keys sort: [:a :b | a printString <= b printString]
]

{ #category : #accessing }
Dictionary >> postCopy [
	array := array collect: [:a | a == nil ifTrue: [nil] ifFalse: [a copy]]
]

{ #category : #accessing }
Dictionary >> printOn: aStream [
	aStream nextPutAll: self class name; nextPutAll: ' ('.
	self associationsDo: [:a | aStream print: a] separatedBy: [aStream space].
	aStream nextPut: $)
]

{ #category : #accessing }
Dictionary >> remove: anObject ifAbsent: aBlock [
	^ self shouldNotImplement
]

{ #category : #accessing }
Dictionary >> removeKey: key <K> ^<V> [
	^ self removeKey: key ifAbsent: [KeyNotFound new key: key; signal: 'key not found: ' , key printString]
]

{ #category : #accessing }
Dictionary >> removeKey: key <K> ifAbsent: aBlock <[^:X]> ^<V | X> [
	| i a |
	key == nil ifTrue: [^ aBlock value].
	i := self indexFor: key.
	a := array at: i.
	a == nil ifTrue: [^ aBlock value].
	self removeAt: i.
	^ a value
]

{ #category : #accessing }
Dictionary >> select: aBlock <[V, ^Boolean]> ^<Self> [
	| out |
	out := self class new.
	self keysAndValuesDo: [:k :v | (aBlock value: v) ifTrue: [out at: k put: v]].
	^ out
]

{ #category : #accessing }
Dictionary >> values ^<Array[V]> [
	| out |
	out := OrderedCollection new: self size.
	self valuesDo: [:v | out add: v].
	^ out asArray
]

{ #category : #accessing }
Dictionary >> valuesDo: aBlock <[V, ^Dynamic]> ^<Self> [
	self associationsDo: [:a | aBlock value: a value]
]
