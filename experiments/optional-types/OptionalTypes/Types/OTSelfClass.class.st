"Self class: the class of the receiver (`class ^<Self class>`), so `self class foo` looks foo up on the receiver's class side."
Class {
	#name : #OTSelfClass,
	#superclass : #OTType
}

{ #category : #testing }
OTSelfClass >> isKnown [
	^ false
]

{ #category : #printing }
OTSelfClass >> printOn: aStream [
	aStream nextPutAll: 'Self class'
]

{ #category : #comparing }
OTSelfClass >> sameAs: aType [
	^ aType class == OTSelfClass
]

{ #category : #substitution }
OTSelfClass >> substitute: aDictionary self: selfType instance: instanceType [
	selfType isNil ifTrue: [^ self].
	selfType isClassType ifTrue: [^ OTMetaType cls: selfType cls selfKind: selfType selfKind].
	^ OTType of: Behavior
]
