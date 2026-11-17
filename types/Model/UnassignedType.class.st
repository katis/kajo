"The type of a temporary before its first assignment: read, it is Dynamic (a block may run after the assignment that follows it in the text, as a recursive block does); joined with an assigned type, it is that type."
Class {
	#name : #UnassignedType,
	#superclass : #DynamicType
}

{ #category : #printing }
UnassignedType >> printOn: aStream [
	aStream nextPutAll: 'Dynamic'
]

{ #category : #testing }
UnassignedType >> isUnassigned [
	^ true
]
