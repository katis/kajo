"Question 9: a protocol made by code in the image, not read from a side file or a method's source: a named set of signatures with an optional parent protocol, for objects that are not Smalltalk classes of their own (a scripting dictionary's classes, an OpenAPI schema, an MCP tool's input). Values of such a type are whatever proxy the bridge answers; the checker only reads the signatures."
Class {
	#name : #OTProtocolInfo,
	#superclass : #OTClassInfo,
	#instVars : [
		'name',
		'parent'
	]
}

{ #category : #accessing }
OTProtocolInfo >> name [
	^ name
]

{ #category : #accessing }
OTProtocolInfo >> parent [
	^ parent
]

{ #category : #accessing }
OTProtocolInfo >> setName: aString parent: aProtocolInfoOrNil [
	self setCls: nil file: 'protocol ' , aString.
	name := aString.
	parent := aProtocolInfoOrNil
]

{ #category : #accessing }
OTProtocolInfo >> signaturesFor: aSelector [
	"{the protocol that declares it. its signatures} from this protocol up, or nil."
	| p |
	p := self.
	[p notNil] whileTrue: [
		(p methods at: aSelector ifAbsent: [nil]) ifNotNil: [:l | ^ {p. l}].
		p := p parent].
	^ nil
]

{ #category : #accessing }
OTProtocolInfo >> includesProtocol: aProtocolInfo [
	| p |
	p := self.
	[p notNil] whileTrue: [p == aProtocolInfo ifTrue: [^ true]. p := p parent].
	^ false
]

{ #category : #'instance creation' }
OTProtocolInfo class >> named: aString parent: aProtocolInfoOrNil [
	^ self new setName: aString parent: aProtocolInfoOrNil
]
