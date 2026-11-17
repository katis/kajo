"Instance: on the class side, an instance of the receiving class (`new ^<Instance>`), so `OrderedCollection new` is an OrderedCollection and a subclass's new is the subclass's. With arguments (`with: <X> ^<Instance[X]>`) it gives the instance's type arguments: a class-side constructor binds the parameters of what it makes."
Class {
	#name : #OTInstance,
	#superclass : #OTType,
	#instVars : [
		'args'
	]
}

{ #category : #accessing }
OTInstance >> args [
	^ args ifNil: [#()]
]

{ #category : #accessing }
OTInstance >> args: anArray [
	args := anArray
]

{ #category : #testing }
OTInstance >> isKnown [
	^ false
]

{ #category : #printing }
OTInstance >> printOn: aStream [
	aStream nextPutAll: 'Instance'.
	self args isEmpty ifFalse: [
		aStream nextPutAll: '['.
		args do: [:a | a printOn: aStream] separatedBy: [aStream nextPutAll: ', '].
		aStream nextPutAll: ']']
]

{ #category : #comparing }
OTInstance >> sameAs: aType [
	^ aType class == OTInstance and: [aType printString = self printString]
]

{ #category : #substitution }
OTInstance >> substitute: aDictionary self: selfType instance: instanceType [
	| a |
	a := self args collect: [:t | t substitute: aDictionary self: selfType instance: instanceType].
	instanceType isNil ifTrue: [^ a isEmpty ifTrue: [self] ifFalse: [OTInstance new args: a; yourself]].
	(a isEmpty or: [instanceType isClassType not]) ifTrue: [^ instanceType].
	^ OTClassType cls: instanceType cls args: a selfKind: instanceType selfKind
]

{ #category : #substitution }
OTInstance >> varsDo: aBlock [
	self args do: [:a | a varsDo: aBlock]
]
