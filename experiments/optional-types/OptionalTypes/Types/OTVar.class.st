"A type variable: a generic class's parameter (E of Collection[E]) or a generic method's variable (X of collect:). Inside the class an element is of the opaque type E; at a send the receiver's arguments and the send's own arguments replace the variables."
Class {
	#name : #OTVar,
	#superclass : #OTType,
	#instVars : [
		'name'
	]
}

{ #category : #testing }
OTVar >> isKnown [
	^ false
]

{ #category : #testing }
OTVar >> isVar [
	^ true
]

{ #category : #accessing }
OTVar >> name [
	^ name
]

{ #category : #printing }
OTVar >> printOn: aStream [
	aStream nextPutAll: name
]

{ #category : #comparing }
OTVar >> sameAs: aType [
	^ aType isVar and: [aType name = name]
]

{ #category : #accessing }
OTVar >> setName: aString [
	name := aString
]

{ #category : #substitution }
OTVar >> substitute: aDictionary self: selfType instance: instanceType [
	^ aDictionary at: name ifAbsent: [self]
]

{ #category : #substitution }
OTVar >> varsDo: aBlock [
	aBlock value: self
]

{ #category : #'instance creation' }
OTVar class >> named: aString [
	^ self new setName: aString
]
