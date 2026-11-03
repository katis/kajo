"Slots that do not keep their referents alive: a slot whose object is collected becomes nil (ADR 0009 section 1)."
Class {
	#name : #WeakArray,
	#superclass : #ArrayedCollection,
	#category : #'Kernel-Collections',
	#type : #weak
}

{ #category : #accessing }
WeakArray >> printOn: aStream [
	aStream nextPutAll: 'a WeakArray('.
	self do: [:e | aStream print: e] separatedBy: [aStream space].
	aStream nextPut: $)
]
