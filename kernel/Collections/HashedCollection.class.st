"Open addressing with linear probing over an Array whose size is a power of two, at most three quarters full. nil marks an empty slot, so nil is not an element."
Class {
	#name : #HashedCollection,
	#superclass : #Collection,
	#instVars : [
		'tally',
		'array'
	]
}

{ #category : #accessing }
HashedCollection >> capacity [
	^ array size
]

{ #category : #accessing }
HashedCollection >> equal: a to: b [
	^ a = b
]

{ #category : #accessing }
HashedCollection >> growIfNeeded [
	tally * 4 >= (array size * 3) ifTrue: [self rehashTo: array size * 2]
]

{ #category : #accessing }
HashedCollection >> hashFor: anObject [
	^ anObject hash
]

{ #category : #accessing }
HashedCollection >> indexFor: key [
	"The slot holding key, or the empty slot where it would go."
	| n i e |
	n := array size.
	i := ((self hashFor: key) bitAnd: n - 1) + 1.
	[(e := array at: i) == nil or: [self equal: (self keyOf: e) to: key]] whileFalse: [
		i := i = n ifTrue: [1] ifFalse: [i + 1]].
	^ i
]

{ #category : #accessing }
HashedCollection >> keyOf: entry [
	^ entry
]

{ #category : #accessing }
HashedCollection >> postCopy [
	array := array copy
]

{ #category : #accessing }
HashedCollection >> rehashTo: newSize [
	"The new table is filled before it replaces the old one (the review fixes, item 10): a reader meanwhile sees the old, whole table, never an empty one."
	| new n |
	new := Array new: newSize.
	n := newSize.
	array do: [:e | | i |
		e == nil ifFalse: [
			i := ((self hashFor: (self keyOf: e)) bitAnd: n - 1) + 1.
			[(new at: i) == nil] whileFalse: [i := i = n ifTrue: [1] ifFalse: [i + 1]].
			new at: i put: e]].
	array := new
]

{ #category : #accessing }
HashedCollection >> removeAll [
	self setCapacity: 8
]

{ #category : #accessing }
HashedCollection >> removeAt: index [
	"Empty the slot and re-place the cluster after it."
	| n i e |
	n := array size.
	array at: index put: nil.
	tally := tally - 1.
	i := index = n ifTrue: [1] ifFalse: [index + 1].
	[(e := array at: i) == nil] whileFalse: [
		array at: i put: nil.
		array at: (self indexFor: (self keyOf: e)) put: e.
		i := i = n ifTrue: [1] ifFalse: [i + 1]]
]

{ #category : #accessing }
HashedCollection >> setCapacity: n [
	| c |
	c := 8.
	[c * 3 < (n * 4)] whileTrue: [c := c * 2].
	array := Array new: c.
	tally := 0
]

{ #category : #accessing }
HashedCollection >> size [
	^ tally
]

{ #category : #accessing }
HashedCollection class >> new [
	^ self new: 8
]

{ #category : #accessing }
HashedCollection class >> new: n [
	^ self basicNew setCapacity: n
]
