"A key and a value; what a Dictionary holds."
Class {
	#name : #Association,
	#superclass : #Magnitude,
	#instVars : [
		'key',
		'value'
	],
	#category : #'Kernel-Collections'
}

{ #category : #accessing }
Association class >> key: k value: v [
	^ self basicNew key: k value: v
]

{ #category : #accessing }
Association >> key: k value: v [
	key := k.
	value := v
]

{ #category : #accessing }
Association >> key [
	^ key
]

{ #category : #accessing }
Association >> key: k [
	key := k
]

{ #category : #accessing }
Association >> value [
	^ value
]

{ #category : #accessing }
Association >> value: v [
	value := v
]

{ #category : #accessing }
Association >> < anAssociation [
	^ key < anAssociation key
]

{ #category : #accessing }
Association >> = anObject [
	^ (anObject isKindOf: Association) and: [key = anObject key and: [value = anObject value]]
]

{ #category : #accessing }
Association >> hash [
	^ key hash
]

{ #category : #accessing }
Association >> printOn: aStream [
	aStream print: key; nextPutAll: '->'; print: value
]
