"A value per object for as long as something else holds the object (the known faults, docs/modules/known-faults.md: a retired method's source, a method's frame variables): keys by identity in a WeakArray, values beside them in an Array. A key collected leaves its slot nil; such records are dropped when a record is added. Lookup is a scan, for small tables. Not synchronized: its owner holds a lock around every use. With a limit, adding past it drops the older half of the records first."
Class {
	#name : #WeakIdentityTable,
	#superclass : #Object,
	#instVars : [
		'keys',
		'values',
		'count',
		'limit'
	]
}

{ #category : #accessing }
WeakIdentityTable >> at: aKey ifAbsent: aBlock [
	keys isNil ifTrue: [^ aBlock value].
	1 to: count do: [:i | (keys at: i) == aKey ifTrue: [^ values at: i]].
	^ aBlock value
]

{ #category : #accessing }
WeakIdentityTable >> at: aKey put: aValue [
	"Keep aValue for aKey (a second record for the same key is not looked for: callers add only what they did not find)."
	keys isNil ifTrue: [
		keys := WeakArray new: 16.
		values := Array new: 16.
		count := 0].
	self prune.
	(limit notNil and: [count >= limit]) ifTrue: [self dropFirst: count // 2].
	count = keys size ifTrue: [self grow].
	count := count + 1.
	keys at: count put: aKey.
	values at: count put: aValue.
	^ aValue
]

{ #category : #accessing }
WeakIdentityTable >> limit: anIntegerOrNil [
	"At most this many records (nil: no limit)."
	limit := anIntegerOrNil
]

{ #category : #accessing }
WeakIdentityTable >> liveCount [
	"How many records have a key still held."
	| n |
	keys isNil ifTrue: [^ 0].
	n := 0.
	1 to: count do: [:i | (keys at: i) isNil ifFalse: [n := n + 1]].
	^ n
]

{ #category : #private }
WeakIdentityTable >> dropFirst: n [
	"Drop the n oldest records."
	1 to: count - n do: [:i |
		keys at: i put: (keys at: i + n).
		values at: i put: (values at: i + n)].
	count - n + 1 to: count do: [:i | keys at: i put: nil. values at: i put: nil].
	count := count - n
]

{ #category : #private }
WeakIdentityTable >> grow [
	| k v |
	k := WeakArray new: keys size * 2.
	v := Array new: keys size * 2.
	1 to: count do: [:i | k at: i put: (keys at: i). v at: i put: (values at: i)].
	keys := k.
	values := v
]

{ #category : #private }
WeakIdentityTable >> prune [
	"Drop the records whose key was collected, keeping the order of the rest."
	| n |
	n := 0.
	1 to: count do: [:i | | k |
		k := keys at: i.
		k isNil ifFalse: [
			n := n + 1.
			keys at: n put: k.
			values at: n put: (values at: i)]].
	n + 1 to: count do: [:i | keys at: i put: nil. values at: i put: nil].
	count := n
]
