"Open addressing with linear probing over an Array whose size is a power of two, at most three quarters full. nil marks an empty slot, so nil is not an element."
Class {
	#name : #HashedCollection,
	#superclass : #Collection,
	#typeParameters : [
		'E'
	],
	#instVars : [
		'tally <Integer>',
		'array <Array>'
	]
}

{ #category : #accessing }
HashedCollection >> capacity ^<Integer> [
	^ array size
]

{ #category : #accessing }
HashedCollection >> equal: a <Object> to: b <Object> ^<Boolean> [
	^ a = b
]

{ #category : #accessing }
HashedCollection >> growIfNeeded ^<Self> [
	tally * 4 >= (array size * 3) ifTrue: [self rehashTo: array size * 2]
]

{ #category : #accessing }
HashedCollection >> hashFor: anObject <Object> ^<Integer> [
	^ anObject hash
]

{ #category : #accessing }
HashedCollection >> indexFor: key <Object> ^<Integer> [
	"The slot holding key, or the empty slot where it would go."
	| n i e |
	n := array size.
	i := ((self hashFor: key) bitAnd: n - 1) + 1.
	[(e := array at: i) == nil or: [self equal: (self keyOf: e) to: key]] whileFalse: [
		i := i = n ifTrue: [1] ifFalse: [i + 1]].
	^ i
]

{ #category : #accessing }
HashedCollection >> keyOf: entry <Object> ^<Object> [
	^ entry
]

{ #category : #accessing }
HashedCollection >> postCopy [
	array := array copy
]

{ #category : #accessing }
HashedCollection >> rehashTo: newSize <Integer> ^<Self> [
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
HashedCollection >> removeAll ^<Self> [
	self setCapacity: 8
]

{ #category : #accessing }
HashedCollection >> removeAt: index <Integer> ^<Self> [
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
HashedCollection >> setCapacity: n <Integer> ^<Self> [
	| c |
	c := 8.
	[c * 3 < (n * 4)] whileTrue: [c := c * 2].
	array := Array new: c.
	tally := 0
]

{ #category : #accessing }
HashedCollection >> size ^<Integer> [
	^ tally
]

{ #category : #accessing }
HashedCollection class >> new ^<Instance> [
	^ self new: 8
]

{ #category : #accessing }
HashedCollection class >> new: n <Integer> ^<Instance> [
	^ self basicNew setCapacity: n
]
