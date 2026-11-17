"The type of a value that answers a protocol made by code (OTProtocolInfo). It refers to the protocol by its name through the annotations' registry, so a protocol replaced under the same name is what every later check sees."
Class {
	#name : #OTProtocolType,
	#superclass : #OTType,
	#instVars : [
		'name'
	]
}

{ #category : #testing }
OTProtocolType >> isProtocolType [
	^ true
]

{ #category : #accessing }
OTProtocolType >> name [
	^ name
]

{ #category : #printing }
OTProtocolType >> printOn: aStream [
	aStream nextPutAll: name
]

{ #category : #comparing }
OTProtocolType >> sameAs: aType [
	^ aType isProtocolType and: [aType name = name]
]

{ #category : #accessing }
OTProtocolType >> setName: aString [
	name := aString
]

{ #category : #'instance creation' }
OTProtocolType class >> named: aString [
	^ self new setName: aString
]
