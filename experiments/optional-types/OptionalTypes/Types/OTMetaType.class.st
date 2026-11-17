"The class object cls or a subclass of it (written `Foo class`): what a class name in a method has, what class-side signatures are looked up in. selfKind #self is the receiver of a class-side method."
Class {
	#name : #OTMetaType,
	#superclass : #OTType,
	#instVars : [
		'cls',
		'selfKind'
	]
}

{ #category : #accessing }
OTMetaType >> cls [
	^ cls
]

{ #category : #testing }
OTMetaType >> isMetaType [
	^ true
]

{ #category : #printing }
OTMetaType >> printOn: aStream [
	aStream nextPutAll: cls name; nextPutAll: ' class'
]

{ #category : #comparing }
OTMetaType >> sameAs: aType [
	^ aType isMetaType and: [aType cls == cls]
]

{ #category : #accessing }
OTMetaType >> selfKind [
	^ selfKind
]

{ #category : #accessing }
OTMetaType >> setCls: aClass selfKind: aSymbol [
	cls := aClass.
	selfKind := aSymbol
]

{ #category : #accessing }
OTMetaType >> withoutSelfMark [
	selfKind isNil ifTrue: [^ self].
	^ OTMetaType cls: cls
]

{ #category : #'instance creation' }
OTMetaType class >> cls: aClass [
	^ self new setCls: aClass selfKind: nil
]

{ #category : #'instance creation' }
OTMetaType class >> cls: aClass selfKind: aSymbol [
	^ self new setCls: aClass selfKind: aSymbol
]
