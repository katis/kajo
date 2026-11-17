"Instance: on the class side, an instance of the receiving class (`new ^<Instance>`), so `OrderedCollection new` is an OrderedCollection and a subclass's new is the subclass's."
Class {
	#name : #OTInstance,
	#superclass : #OTType
}

{ #category : #testing }
OTInstance >> isKnown [
	^ false
]

{ #category : #printing }
OTInstance >> printOn: aStream [
	aStream nextPutAll: 'Instance'
]

{ #category : #comparing }
OTInstance >> sameAs: aType [
	^ aType class == OTInstance
]

{ #category : #substitution }
OTInstance >> substitute: aDictionary self: selfType instance: instanceType [
	^ instanceType ifNil: [self]
]
