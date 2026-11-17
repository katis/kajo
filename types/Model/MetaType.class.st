"The class object cls or a subclass of it (written `Foo class`): what a class name in a method has, what class-side signatures are looked up in. selfKind #self is the receiver of a class-side method."
Class {
	#name : #MetaType,
	#superclass : #Type,
	#instVars : [
		'cls',
		'selfKind'
	]
}

{ #category : #accessing }
MetaType >> cls [
	^ cls
]

{ #category : #accessing }
MetaType >> selfKind [
	^ selfKind
]

{ #category : #accessing }
MetaType >> setCls: aClass selfKind: aSymbol [
	cls := aClass.
	selfKind := aSymbol
]

{ #category : #accessing }
MetaType >> withoutSelfMark [
	selfKind isNil ifTrue: [^ self].
	^ MetaType cls: cls
]

{ #category : #comparing }
MetaType >> sameAs: aType [
	^ aType isMetaType and: [aType cls == cls]
]

{ #category : #printing }
MetaType >> printOn: aStream [
	aStream nextPutAll: cls name; nextPutAll: ' class'
]

{ #category : #testing }
MetaType >> isMetaType [
	^ true
]

{ #category : #'instance creation' }
MetaType class >> cls: aClass [
	^ self new setCls: aClass selfKind: nil
]

{ #category : #'instance creation' }
MetaType class >> cls: aClass selfKind: aSymbol [
	^ self new setCls: aClass selfKind: aSymbol
]
