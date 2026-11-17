"Self class: the class of the receiver (`class ^<Self class>`), so `self class foo` looks foo up on the receiver's class side."
Class {
	#name : #SelfClassType,
	#superclass : #Type
}

{ #category : #comparing }
SelfClassType >> sameAs: aType [
	^ aType class == SelfClassType
]

{ #category : #printing }
SelfClassType >> printOn: aStream [
	aStream nextPutAll: 'Self class'
]

{ #category : #substitution }
SelfClassType >> substitute: aDictionary self: selfType instance: instanceType [
	selfType isNil ifTrue: [^ self].
	selfType isClassType ifTrue: [^ MetaType cls: selfType cls selfKind: selfType selfKind].
	^ Type of: Behavior
]

{ #category : #testing }
SelfClassType >> isKnown [
	^ false
]
