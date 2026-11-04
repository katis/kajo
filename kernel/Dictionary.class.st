"Keys to values, by = and hash; the entries are Associations."
Class {
	#name : #Dictionary,
	#superclass : #HashedCollection,
	#category : #'Kernel-Collections'
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
Dictionary >> add: anAssociation [
	self at: anAssociation key put: anAssociation value.
	^ anAssociation
]

{ #category : #accessing }
Dictionary >> associations [
	| out |
	out := OrderedCollection new: self size.
	self associationsDo: [:a | out add: a].
	^ out asArray
]

{ #category : #accessing }
Dictionary >> associationsDo: aBlock [
	array do: [:a | a == nil ifFalse: [aBlock value: a]]
]

{ #category : #accessing }
Dictionary >> associationsDo: aBlock separatedBy: sepBlock [
	| first |
	first := true.
	self associationsDo: [:a | first ifFalse: [sepBlock value]. first := false. aBlock value: a]
]

{ #category : #accessing }
Dictionary >> at: key [
	^ self at: key ifAbsent: [KeyNotFound new key: key; signal: 'key not found: ' , key printString]
]

{ #category : #accessing }
Dictionary >> at: key ifAbsent: aBlock [
	| a |
	key == nil ifTrue: [^ aBlock value].
	a := array at: (self indexFor: key).
	a == nil ifTrue: [^ aBlock value].
	^ a value
]

{ #category : #accessing }
Dictionary >> at: key ifAbsentPut: aBlock [
	^ self at: key ifAbsent: [self at: key put: aBlock value]
]

{ #category : #accessing }
Dictionary >> at: key ifPresent: aBlock [
	^ aBlock cull: (self at: key ifAbsent: [^ nil])
]

{ #category : #accessing }
Dictionary >> at: key ifPresent: presentBlock ifAbsent: absentBlock [
	^ presentBlock cull: (self at: key ifAbsent: [^ absentBlock value])
]

{ #category : #accessing }
Dictionary >> at: key put: value [
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
Dictionary >> collect: aBlock [
	| out |
	out := self class new: self size.
	self keysAndValuesDo: [:k :v | out at: k put: (aBlock value: v)].
	^ out
]

{ #category : #accessing }
Dictionary >> do: aBlock [
	self valuesDo: aBlock
]

{ #category : #accessing }
Dictionary >> hash [
	^ self size
]

{ #category : #accessing }
Dictionary >> includes: value [
	^ self anySatisfy: [:v | v = value]
]

{ #category : #accessing }
Dictionary >> includesKey: key [
	key == nil ifTrue: [^ false].
	^ (array at: (self indexFor: key)) notNil
]

{ #category : #accessing }
Dictionary >> keyAtValue: value [
	^ self keyAtValue: value ifAbsent: [nil]
]

{ #category : #accessing }
Dictionary >> keyAtValue: value ifAbsent: aBlock [
	self keysAndValuesDo: [:k :v | v = value ifTrue: [^ k]].
	^ aBlock value
]

{ #category : #accessing }
Dictionary >> keyOf: entry [
	^ entry key
]

{ #category : #accessing }
Dictionary >> keys [
	| out |
	out := OrderedCollection new: self size.
	self keysDo: [:k | out add: k].
	^ out asArray
]

{ #category : #accessing }
Dictionary >> keysAndValuesDo: aBlock [
	self associationsDo: [:a | aBlock value: a key value: a value]
]

{ #category : #accessing }
Dictionary >> keysDo: aBlock [
	self associationsDo: [:a | aBlock value: a key]
]

{ #category : #accessing }
Dictionary >> keysSortedSafely [
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
Dictionary >> removeKey: key [
	^ self removeKey: key ifAbsent: [KeyNotFound new key: key; signal: 'key not found: ' , key printString]
]

{ #category : #accessing }
Dictionary >> removeKey: key ifAbsent: aBlock [
	| i a |
	key == nil ifTrue: [^ aBlock value].
	i := self indexFor: key.
	a := array at: i.
	a == nil ifTrue: [^ aBlock value].
	self removeAt: i.
	^ a value
]

{ #category : #accessing }
Dictionary >> select: aBlock [
	| out |
	out := self class new.
	self keysAndValuesDo: [:k :v | (aBlock value: v) ifTrue: [out at: k put: v]].
	^ out
]

{ #category : #accessing }
Dictionary >> values [
	| out |
	out := OrderedCollection new: self size.
	self valuesDo: [:v | out add: v].
	^ out asArray
]

{ #category : #accessing }
Dictionary >> valuesDo: aBlock [
	self associationsDo: [:a | aBlock value: a value]
]
