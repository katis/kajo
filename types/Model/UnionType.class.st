"A value of one of the member types (`Integer | Nil`). Made by Type class>>union: only, so the members are flat, distinct, at least two and never dynamic."
Class {
	#name : #UnionType,
	#superclass : #Type,
	#instVars : [
		'members'
	]
}

{ #category : #accessing }
UnionType >> members [
	^ members
]

{ #category : #accessing }
UnionType >> setMembers: anArray [
	members := anArray
]

{ #category : #accessing }
UnionType >> withoutNil [
	^ Type union: (members reject: [:m | m isNilType])
]

{ #category : #accessing }
UnionType >> withoutSelfMark [
	^ Type union: (members collect: [:m | m withoutSelfMark])
]

{ #category : #comparing }
UnionType >> sameAs: aType [
	aType isUnion ifFalse: [^ false].
	aType members size = members size ifFalse: [^ false].
	^ members allSatisfy: [:m | aType members anySatisfy: [:x | x sameAs: m]]
]

{ #category : #printing }
UnionType >> printOn: aStream [
	members do: [:m | m printOn: aStream] separatedBy: [aStream nextPutAll: ' | ']
]

{ #category : #substitution }
UnionType >> substitute: aDictionary self: selfType instance: instanceType [
	^ Type union: (members collect: [:m | m substitute: aDictionary self: selfType instance: instanceType])
]

{ #category : #substitution }
UnionType >> varsDo: aBlock [
	members do: [:m | m varsDo: aBlock]
]

{ #category : #testing }
UnionType >> includesNil [
	^ members anySatisfy: [:m | m isNilType]
]

{ #category : #testing }
UnionType >> isKnown [
	^ members allSatisfy: [:m | m isKnown]
]

{ #category : #testing }
UnionType >> isUnion [
	^ true
]
