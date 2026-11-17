"Self: the type of the receiver, whatever subclass it is (`yourself ^<Self>`, `copy ^<Self>`). At a send it is the receiver's type; in a method's body only self (and what answers Self) has it."
Class {
	#name : #OTSelf,
	#superclass : #OTType
}

{ #category : #testing }
OTSelf >> isKnown [
	^ false
]

{ #category : #printing }
OTSelf >> printOn: aStream [
	aStream nextPutAll: 'Self'
]

{ #category : #comparing }
OTSelf >> sameAs: aType [
	^ aType class == OTSelf
]

{ #category : #substitution }
OTSelf >> substitute: aDictionary self: selfType instance: instanceType [
	^ selfType ifNil: [self]
]
