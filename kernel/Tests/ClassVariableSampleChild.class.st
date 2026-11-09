"A subclass of ClassVariableSample: it sees the same class variable (module 8d)."
Class {
	#name : #ClassVariableSampleChild,
	#superclass : #ClassVariableSample
}

{ #category : #accessing }
ClassVariableSampleChild >> bumpTwice [
	self bump.
	^ Count := Count + 1
]

{ #category : #accessing }
ClassVariableSampleChild class >> seen [
	^ Count
]
