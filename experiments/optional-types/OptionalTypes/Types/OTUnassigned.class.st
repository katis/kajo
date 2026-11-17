"The type of a temporary before its first assignment: read, it is Dynamic (a block may run after the assignment that follows it in the text, as a recursive block does); joined with an assigned type, it is that type."
Class {
	#name : #OTUnassigned,
	#superclass : #OTDynamic
}

{ #category : #testing }
OTUnassigned >> isUnassigned [
	^ true
]

{ #category : #printing }
OTUnassigned >> printOn: aStream [
	aStream nextPutAll: 'Dynamic'
]
