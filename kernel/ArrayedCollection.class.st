"Fixed-size sequences whose elements are the object's indexed slots or bytes."
Class {
	#name : #ArrayedCollection,
	#superclass : #SequenceableCollection,
	#category : #'Kernel-Collections'
}

{ #category : #accessing }
ArrayedCollection >> add: anObject [
	^ self shouldNotImplement
]

{ #category : #accessing }
ArrayedCollection >> size [
	<primitive: 95>
	^ 0
]

{ #category : #accessing }
ArrayedCollection class >> new [
	^ self new: 0
]

{ #category : #accessing }
ArrayedCollection class >> new: n withAll: anObject [
	^ (self new: n) atAllPut: anObject; yourself
]

{ #category : #accessing }
ArrayedCollection class >> streamContents: aBlock [
	| s |
	s := WriteStream on: (self new: 0).
	aBlock value: s.
	^ s contents
]

{ #category : #accessing }
ArrayedCollection class >> with: a [
	^ (self new: 1) at: 1 put: a; yourself
]

{ #category : #accessing }
ArrayedCollection class >> with: a with: b [
	^ (self new: 2) at: 1 put: a; at: 2 put: b; yourself
]

{ #category : #accessing }
ArrayedCollection class >> with: a with: b with: c [
	^ (self new: 3) at: 1 put: a; at: 2 put: b; at: 3 put: c; yourself
]

{ #category : #accessing }
ArrayedCollection class >> with: a with: b with: c with: d [
	^ (self new: 4) at: 1 put: a; at: 2 put: b; at: 3 put: c; at: 4 put: d; yourself
]

{ #category : #accessing }
ArrayedCollection class >> withAll: aCollection [
	| out i |
	out := self new: aCollection size.
	i := 0.
	aCollection do: [:e | out at: (i := i + 1) put: e].
	^ out
]
