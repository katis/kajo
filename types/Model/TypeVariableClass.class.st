"X class: the class of a generic method's variable, bound from a class passed as an argument (`on: <X class> do: <[X, ^R]>`: the handler's argument is an instance of the exception class handled)."
Class {
	#name : #TypeVariableClass,
	#superclass : #Type,
	#instVars : [
		'name'
	]
}

{ #category : #accessing }
TypeVariableClass >> name [
	^ name
]

{ #category : #accessing }
TypeVariableClass >> setName: aString [
	name := aString
]

{ #category : #comparing }
TypeVariableClass >> sameAs: aType [
	^ aType class == TypeVariableClass and: [aType name = name]
]

{ #category : #printing }
TypeVariableClass >> printOn: aStream [
	aStream nextPutAll: name; nextPutAll: ' class'
]

{ #category : #substitution }
TypeVariableClass >> substitute: aDictionary self: selfType instance: instanceType [
	| t |
	t := aDictionary at: name ifAbsent: [^ self].
	t isClassType ifTrue: [^ MetaType cls: t cls].
	^ Type dynamic
]

{ #category : #substitution }
TypeVariableClass >> varsDo: aBlock [
	aBlock value: (TypeVariable named: name)
]

{ #category : #testing }
TypeVariableClass >> isKnown [
	^ false
]

{ #category : #'instance creation' }
TypeVariableClass class >> named: aString [
	^ self new setName: aString
]
