"X class: the class of a generic method's variable, bound from a class passed as an argument (`on: <X class> do: <[X, ^R]>`: the handler's argument is an instance of the exception class handled)."
Class {
	#name : #OTVarClass,
	#superclass : #OTType,
	#instVars : [
		'name'
	]
}

{ #category : #testing }
OTVarClass >> isKnown [
	^ false
]

{ #category : #accessing }
OTVarClass >> name [
	^ name
]

{ #category : #printing }
OTVarClass >> printOn: aStream [
	aStream nextPutAll: name; nextPutAll: ' class'
]

{ #category : #comparing }
OTVarClass >> sameAs: aType [
	^ aType class == OTVarClass and: [aType name = name]
]

{ #category : #accessing }
OTVarClass >> setName: aString [
	name := aString
]

{ #category : #substitution }
OTVarClass >> substitute: aDictionary self: selfType instance: instanceType [
	| t |
	t := aDictionary at: name ifAbsent: [^ self].
	t isClassType ifTrue: [^ OTMetaType cls: t cls].
	^ OTType dynamic
]

{ #category : #substitution }
OTVarClass >> varsDo: aBlock [
	aBlock value: (OTVar named: name)
]

{ #category : #'instance creation' }
OTVarClass class >> named: aString [
	^ self new setName: aString
]
