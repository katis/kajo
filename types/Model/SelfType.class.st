"Self: the type of the receiver, whatever subclass it is (`yourself ^<Self>`, `copy ^<Self>`). At a send it is the receiver's type; in a method's body only self (and what answers Self) has it."
Class {
	#name : #SelfType,
	#superclass : #Type
}

{ #category : #comparing }
SelfType >> sameAs: aType [
	^ aType class == SelfType
]

{ #category : #printing }
SelfType >> printOn: aStream [
	aStream nextPutAll: 'Self'
]

{ #category : #substitution }
SelfType >> substitute: aDictionary self: selfType instance: instanceType [
	^ selfType ifNil: [self]
]

{ #category : #testing }
SelfType >> isKnown [
	^ false
]
