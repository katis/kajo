"A value of one of the member types (`Integer | Nil`). Made by OTType class>>union: only, so the members are flat, distinct, at least two and never dynamic."
Class {
	#name : #OTUnion,
	#superclass : #OTType,
	#instVars : [
		'members'
	]
}

{ #category : #testing }
OTUnion >> includesNil [
	^ members anySatisfy: [:m | m isNilType]
]

{ #category : #testing }
OTUnion >> isKnown [
	^ members allSatisfy: [:m | m isKnown]
]

{ #category : #testing }
OTUnion >> isUnion [
	^ true
]

{ #category : #accessing }
OTUnion >> members [
	^ members
]

{ #category : #printing }
OTUnion >> printOn: aStream [
	members do: [:m | m printOn: aStream] separatedBy: [aStream nextPutAll: ' | ']
]

{ #category : #comparing }
OTUnion >> sameAs: aType [
	aType isUnion ifFalse: [^ false].
	aType members size = members size ifFalse: [^ false].
	^ members allSatisfy: [:m | aType members anySatisfy: [:x | x sameAs: m]]
]

{ #category : #accessing }
OTUnion >> setMembers: anArray [
	members := anArray
]

{ #category : #substitution }
OTUnion >> substitute: aDictionary self: selfType instance: instanceType [
	^ OTType union: (members collect: [:m | m substitute: aDictionary self: selfType instance: instanceType])
]

{ #category : #substitution }
OTUnion >> varsDo: aBlock [
	members do: [:m | m varsDo: aBlock]
]

{ #category : #accessing }
OTUnion >> withoutNil [
	^ OTType union: (members reject: [:m | m isNilType])
]

{ #category : #accessing }
OTUnion >> withoutSelfMark [
	^ OTType union: (members collect: [:m | m withoutSelfMark])
]
