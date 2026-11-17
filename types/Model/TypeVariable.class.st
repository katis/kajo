"A type variable: a generic class's parameter (E of Collection[E]) or a generic method's variable (X of collect:). Inside the class an element is of the opaque type E; at a send the receiver's arguments and the send's own arguments replace the variables."
Class {
	#name : #TypeVariable,
	#superclass : #Type,
	#instVars : [
		'name'
	]
}

{ #category : #accessing }
TypeVariable >> name [
	^ name
]

{ #category : #accessing }
TypeVariable >> setName: aString [
	name := aString
]

{ #category : #comparing }
TypeVariable >> sameAs: aType [
	^ aType isVar and: [aType name = name]
]

{ #category : #printing }
TypeVariable >> printOn: aStream [
	aStream nextPutAll: name
]

{ #category : #substitution }
TypeVariable >> substitute: aDictionary self: selfType instance: instanceType [
	^ aDictionary at: name ifAbsent: [self]
]

{ #category : #substitution }
TypeVariable >> varsDo: aBlock [
	aBlock value: self
]

{ #category : #testing }
TypeVariable >> isKnown [
	^ false
]

{ #category : #testing }
TypeVariable >> isVar [
	^ true
]

{ #category : #'instance creation' }
TypeVariable class >> named: aString [
	^ self new setName: aString
]
