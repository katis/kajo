"Pointer slots, indexed from 1. Array literals are read-only."
Class {
	#name : #Array,
	#superclass : #ArrayedCollection,
	#typeParameters : [
		'E'
	],
	#type : #variable
}

{ #category : #accessing }
Array >> asArray ^<Self> [
	^ self
]

{ #category : #accessing }
Array >> collect: aBlock <[E, ^:X]> ^<Array[X]>

{ #category : #accessing }
Array >> isArray ^<Boolean> [
	^ true
]

{ #category : #accessing }
Array >> isLiteral ^<Boolean> [
	^ self allSatisfy: [:e | e isLiteral]
]

{ #category : #accessing }
Array >> printOn: aStream <WriteStream> ^<Self> [
	aStream nextPutAll: '#('.
	self do: [:e | aStream print: e] separatedBy: [aStream space].
	aStream nextPut: $)
]

{ #category : #accessing }
Array >> replaceFrom: start to: stop with: aCollection startingAt: from [
	<primitive: 38>
	^ super replaceFrom: start to: stop with: aCollection startingAt: from
]
