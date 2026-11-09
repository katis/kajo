"Pointer slots, indexed from 1. Array literals are read-only."
Class {
	#name : #Array,
	#superclass : #ArrayedCollection,
	#type : #variable
}

{ #category : #accessing }
Array >> asArray [
	^ self
]

{ #category : #accessing }
Array >> isArray [
	^ true
]

{ #category : #accessing }
Array >> isLiteral [
	^ self allSatisfy: [:e | e isLiteral]
]

{ #category : #accessing }
Array >> printOn: aStream [
	aStream nextPutAll: '#('.
	self do: [:e | aStream print: e] separatedBy: [aStream space].
	aStream nextPut: $)
]

{ #category : #accessing }
Array >> replaceFrom: start to: stop with: aCollection startingAt: from [
	<primitive: 38>
	^ super replaceFrom: start to: stop with: aCollection startingAt: from
]
