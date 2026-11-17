"The type of a value that answers a protocol made by code (TypeProtocol). It refers to the protocol by its name through the type table's registry (TypeTable>>register:), so a protocol replaced under the same name is what every later check sees."
Class {
	#name : #ProtocolType,
	#superclass : #Type,
	#instVars : [
		'name'
	]
}

{ #category : #accessing }
ProtocolType >> name [
	^ name
]

{ #category : #accessing }
ProtocolType >> setName: aString [
	name := aString
]

{ #category : #comparing }
ProtocolType >> sameAs: aType [
	^ aType isProtocolType and: [aType name = name]
]

{ #category : #printing }
ProtocolType >> printOn: aStream [
	aStream nextPutAll: name
]

{ #category : #testing }
ProtocolType >> isProtocolType [
	^ true
]

{ #category : #'instance creation' }
ProtocolType class >> named: aString [
	^ self new setName: aString
]
