"Instance: on the class side, an instance of the receiving class (`new ^<Instance>`), so `OrderedCollection new` is an OrderedCollection and a subclass's new is the subclass's. With arguments (`with: <X> ^<Instance[X]>`) it gives the instance's type arguments: a class-side constructor binds the parameters of what it makes."
Class {
	#name : #InstanceType,
	#superclass : #Type,
	#instVars : [
		'args'
	]
}

{ #category : #accessing }
InstanceType >> args [
	^ args ifNil: [#()]
]

{ #category : #accessing }
InstanceType >> args: anArray [
	args := anArray
]

{ #category : #comparing }
InstanceType >> sameAs: aType [
	^ aType class == InstanceType and: [aType printString = self printString]
]

{ #category : #printing }
InstanceType >> printOn: aStream [
	aStream nextPutAll: 'Instance'.
	self args isEmpty ifFalse: [
		aStream nextPutAll: '['.
		args do: [:a | a printOn: aStream] separatedBy: [aStream nextPutAll: ', '].
		aStream nextPutAll: ']']
]

{ #category : #substitution }
InstanceType >> substitute: aDictionary self: selfType instance: instanceType [
	| a |
	a := self args collect: [:t | t substitute: aDictionary self: selfType instance: instanceType].
	instanceType isNil ifTrue: [^ a isEmpty ifTrue: [self] ifFalse: [InstanceType new args: a; yourself]].
	(a isEmpty or: [instanceType isClassType not]) ifTrue: [^ instanceType].
	^ NominalType cls: instanceType cls args: a selfKind: instanceType selfKind
]

{ #category : #substitution }
InstanceType >> varsDo: aBlock [
	self args do: [:a | a varsDo: aBlock]
]

{ #category : #testing }
InstanceType >> isKnown [
	^ false
]
