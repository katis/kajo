"Fixed-size sequences whose elements are the object's indexed slots or bytes."
Class {
	#name : #ArrayedCollection,
	#superclass : #SequenceableCollection,
	#typeParameters : [
		'E'
	]
}

{ #category : #accessing }
ArrayedCollection >> add: anObject <E> ^<E> [
	^ self shouldNotImplement
]

{ #category : #accessing }
ArrayedCollection >> size ^<Integer> [
	<primitive: 95>
	^ 0
]

{ #category : #accessing }
ArrayedCollection class >> new ^<Instance> [
	^ self new: 0
]

{ #category : #accessing }
ArrayedCollection class >> new: size <Integer> ^<Instance>

{ #category : #accessing }
ArrayedCollection class >> new: n <Integer> withAll: anObject <:X> ^<Instance[X]> [
	^ (self new: n) atAllPut: anObject; yourself
]

{ #category : #accessing }
ArrayedCollection class >> streamContents: aBlock <[WriteStream[Instance], ^Dynamic]> ^<Instance> [
	| s |
	s := WriteStream on: (self new: 0).
	aBlock value: s.
	^ s contents
]

{ #category : #accessing }
ArrayedCollection class >> with: a <:X> ^<Instance[X]> [
	^ (self new: 1) at: 1 put: a; yourself
]

{ #category : #accessing }
ArrayedCollection class >> with: a <:X> with: b <X> ^<Instance[X]> [
	^ (self new: 2) at: 1 put: a; at: 2 put: b; yourself
]

{ #category : #accessing }
ArrayedCollection class >> with: a <:X> with: b <X> with: c <X> ^<Instance[X]> [
	^ (self new: 3) at: 1 put: a; at: 2 put: b; at: 3 put: c; yourself
]

{ #category : #accessing }
ArrayedCollection class >> with: a <:X> with: b <X> with: c <X> with: d <X> ^<Instance[X]> [
	^ (self new: 4) at: 1 put: a; at: 2 put: b; at: 3 put: c; at: 4 put: d; yourself
]

{ #category : #accessing }
ArrayedCollection class >> withAll: aCollection <Collection[:X]> ^<Instance[X]> [
	| out i |
	out := self new: aCollection size.
	i := 0.
	aCollection do: [:e | out at: (i := i + 1) put: e].
	^ out
]
