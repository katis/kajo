"A protocol made by code (the experiment's question 9, the owner's answer: protocol types are made by code only): not read from a method's source or a class definition: a named set of signatures with an optional parent protocol, for objects that are not Smalltalk classes of their own (a scripting dictionary's classes, an OpenAPI schema, an MCP tool's input). Values of such a type are whatever proxy the bridge answers; the checker only reads the signatures."
Class {
	#name : #TypeProtocol,
	#superclass : #TypedClass,
	#instVars : [
		'name',
		'parent'
	]
}

{ #category : #accessing }
TypeProtocol >> includesProtocol: aProtocolInfo [
	| p |
	p := self.
	[p notNil] whileTrue: [p == aProtocolInfo ifTrue: [^ true]. p := p parent].
	^ false
]

{ #category : #accessing }
TypeProtocol >> name [
	^ name
]

{ #category : #accessing }
TypeProtocol >> parent [
	^ parent
]

{ #category : #accessing }
TypeProtocol >> setName: aString parent: aProtocolInfoOrNil [
	self setCls: nil.
	name := aString.
	parent := aProtocolInfoOrNil
]

{ #category : #accessing }
TypeProtocol >> signaturesFor: aSelector [
	"{the protocol that declares it. its signatures} from this protocol up, or nil."
	| p |
	p := self.
	[p notNil] whileTrue: [
		(p methods at: aSelector ifAbsent: [nil]) ifNotNil: [:l | ^ {p. l}].
		p := p parent].
	^ nil
]

{ #category : #'instance creation' }
TypeProtocol class >> named: aString parent: aProtocolInfoOrNil [
	^ self new setName: aString parent: aProtocolInfoOrNil
]
