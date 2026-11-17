"An instance of cls or of a subclass, with the generic class's arguments (empty: every parameter dynamic). selfKind is nil, #self (the receiver's own type inside a method: what Self accepts) or #instance (an instance of the receiver class on the class side: what Instance accepts)."
Class {
	#name : #OTClassType,
	#superclass : #OTType,
	#instVars : [
		'cls',
		'args',
		'selfKind'
	]
}

{ #category : #accessing }
OTClassType >> args [
	^ args
]

{ #category : #accessing }
OTClassType >> cls [
	^ cls
]

{ #category : #testing }
OTClassType >> includesNil [
	^ cls == UndefinedObject
]

{ #category : #testing }
OTClassType >> isClassType [
	^ true
]

{ #category : #testing }
OTClassType >> isNilType [
	^ cls == UndefinedObject
]

{ #category : #printing }
OTClassType >> printOn: aStream [
	cls == UndefinedObject ifTrue: [^ aStream nextPutAll: 'Nil'].
	aStream nextPutAll: cls name.
	args isEmpty ifFalse: [
		aStream nextPutAll: '['.
		args do: [:a | a printOn: aStream] separatedBy: [aStream nextPutAll: ', '].
		aStream nextPutAll: ']']
]

{ #category : #comparing }
OTClassType >> sameAs: aType [
	aType isClassType ifFalse: [^ false].
	aType cls == cls ifFalse: [^ false].
	aType args size = args size ifFalse: [^ false].
	1 to: args size do: [:i | ((args at: i) sameAs: (aType args at: i)) ifFalse: [^ false]].
	^ true
]

{ #category : #accessing }
OTClassType >> selfKind [
	^ selfKind
]

{ #category : #accessing }
OTClassType >> setCls: aClass args: anArray selfKind: aSymbol [
	cls := aClass.
	args := anArray.
	selfKind := aSymbol
]

{ #category : #substitution }
OTClassType >> substitute: aDictionary self: selfType instance: instanceType [
	args isEmpty ifTrue: [^ self].
	^ OTClassType cls: cls args: (args collect: [:a | a substitute: aDictionary self: selfType instance: instanceType]) selfKind: selfKind
]

{ #category : #substitution }
OTClassType >> varsDo: aBlock [
	args do: [:a | a varsDo: aBlock]
]

{ #category : #accessing }
OTClassType >> withoutSelfMark [
	selfKind isNil ifTrue: [^ self].
	^ OTClassType cls: cls args: args
]

{ #category : #'instance creation' }
OTClassType class >> cls: aClass args: anArray [
	^ self new setCls: aClass args: anArray selfKind: nil
]

{ #category : #'instance creation' }
OTClassType class >> cls: aClass args: anArray selfKind: aSymbol [
	^ self new setCls: aClass args: anArray selfKind: aSymbol
]
