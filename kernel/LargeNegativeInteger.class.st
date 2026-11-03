"A negative integer beyond the SmallInteger range (its magnitude in bytes)."
Class {
	#name : #LargeNegativeInteger,
	#superclass : #LargePositiveInteger,
	#category : #'Kernel-Numbers'
}

{ #category : #accessing }
LargeNegativeInteger >> negative [
	^ true
]
