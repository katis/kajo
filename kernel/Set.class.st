"Unordered, no duplicates (by = and hash)."
Class {
	#name : #Set,
	#superclass : #HashedCollection,
	#category : #'Kernel-Collections'
}

{ #category : #accessing }
Set >> add: anObject [
	| i |
	anObject == nil ifTrue: [^ self error: 'a Set cannot hold nil'].
	i := self indexFor: anObject.
	(array at: i) == nil ifTrue: [
		array at: i put: anObject.
		tally := tally + 1.
		self growIfNeeded].
	^ anObject
]

{ #category : #accessing }
Set >> includes: anObject [
	anObject == nil ifTrue: [^ false].
	^ (array at: (self indexFor: anObject)) notNil
]

{ #category : #accessing }
Set >> remove: anObject ifAbsent: aBlock [
	| i |
	anObject == nil ifTrue: [^ aBlock value].
	i := self indexFor: anObject.
	(array at: i) == nil ifTrue: [^ aBlock value].
	self removeAt: i.
	^ anObject
]

{ #category : #accessing }
Set >> do: aBlock [
	array do: [:e | e == nil ifFalse: [aBlock value: e]]
]

{ #category : #accessing }
Set >> collect: aBlock [
	| out |
	out := Set new.
	self do: [:e | out add: (aBlock value: e)].
	^ out
]

{ #category : #accessing }
Set >> = aSet [
	self == aSet ifTrue: [^ true].
	(aSet isKindOf: Set) ifFalse: [^ false].
	self size = aSet size ifFalse: [^ false].
	^ self allSatisfy: [:e | aSet includes: e]
]

{ #category : #accessing }
Set >> hash [
	^ self size
]
