"The read-only bit (ADR 0009 section 9): a refused store signals ModificationForbidden."
Class {
	#name : #ReadOnlyTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
ReadOnlyTest >> testStoresIntoReadOnlyObjectsSignal [
	| a e |
	a := Array new: 2.
	a beReadOnly.
	self assert: a isReadOnly.
	e := [a at: 1 put: 3. #stored] on: ModificationForbidden do: [:ex | ex].
	self assert: e class == ModificationForbidden.
	self assert: e object == a.
	self assert: e index = 1.
	self assert: e value = 3.
	self assert: (a at: 1) isNil.
	a beWritable.
	a at: 1 put: 3.
	self assert: (a at: 1) = 3
]

{ #category : #accessing }
ReadOnlyTest >> testInstanceVariableStoreIntoReadOnly [
	| assoc r |
	assoc := 1 -> 2.
	assoc beReadOnly.
	r := [assoc value: 5. #stored] on: ModificationForbidden do: [:ex | ex resume: nil].
	self assert: r == #stored.
	self assert: assoc value = 2
]

{ #category : #accessing }
ReadOnlyTest >> testMethodLiteralsAreReadOnly [
	| lit |
	lit := self literalArray.
	self assert: lit isReadOnly.
	self should: [lit at: 1 put: 0] raise: ModificationForbidden.
	self assert: (lit at: 1) = 1.
	self assert: 'literal' isReadOnly.
	self assert: 3 isReadOnly
]

{ #category : #accessing }
ReadOnlyTest >> literalArray [
	^ #(1 2 3)
]
