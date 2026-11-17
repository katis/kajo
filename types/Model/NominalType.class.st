"An instance of cls or of a subclass, with the generic class's arguments (empty: every parameter dynamic): Integer, Array[E]. selfKind is nil, #self (the receiver's own type inside a method: what Self accepts) or #instance (an instance of the receiver class on the class side, or made by self class or self species on the instance side: what Instance accepts). The experiment's OTClassType (the kernel has ClassTypes, the class-level types' text)."
Class {
	#name : #NominalType,
	#superclass : #Type,
	#instVars : [
		'cls',
		'args',
		'selfKind'
	]
}

{ #category : #accessing }
NominalType >> args [
	^ args
]

{ #category : #accessing }
NominalType >> cls [
	^ cls
]

{ #category : #accessing }
NominalType >> selfKind [
	^ selfKind
]

{ #category : #accessing }
NominalType >> setCls: aClass args: anArray selfKind: aSymbol [
	cls := aClass.
	args := anArray.
	selfKind := aSymbol
]

{ #category : #accessing }
NominalType >> withoutSelfMark [
	selfKind isNil ifTrue: [^ self].
	^ NominalType cls: cls args: args
]

{ #category : #comparing }
NominalType >> sameAs: aType [
	aType isClassType ifFalse: [^ false].
	aType cls == cls ifFalse: [^ false].
	aType args size = args size ifFalse: [^ false].
	1 to: args size do: [:i | ((args at: i) sameAs: (aType args at: i)) ifFalse: [^ false]].
	^ true
]

{ #category : #printing }
NominalType >> printOn: aStream [
	cls == UndefinedObject ifTrue: [^ aStream nextPutAll: 'Nil'].
	aStream nextPutAll: cls name.
	args isEmpty ifFalse: [
		aStream nextPutAll: '['.
		args do: [:a | a printOn: aStream] separatedBy: [aStream nextPutAll: ', '].
		aStream nextPutAll: ']']
]

{ #category : #substitution }
NominalType >> substitute: aDictionary self: selfType instance: instanceType [
	args isEmpty ifTrue: [^ self].
	^ NominalType cls: cls args: (args collect: [:a | a substitute: aDictionary self: selfType instance: instanceType]) selfKind: selfKind
]

{ #category : #substitution }
NominalType >> varsDo: aBlock [
	args do: [:a | a varsDo: aBlock]
]

{ #category : #testing }
NominalType >> includesNil [
	^ cls == UndefinedObject
]

{ #category : #testing }
NominalType >> isClassType [
	^ true
]

{ #category : #testing }
NominalType >> isNilType [
	^ cls == UndefinedObject
]

{ #category : #'instance creation' }
NominalType class >> cls: aClass args: anArray [
	^ self new setCls: aClass args: anArray selfKind: nil
]

{ #category : #'instance creation' }
NominalType class >> cls: aClass args: anArray selfKind: aSymbol [
	^ self new setCls: aClass args: anArray selfKind: aSymbol
]
