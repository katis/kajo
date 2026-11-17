"One annotated method: its selector, the argument types, the result type (Dynamic when the side file gives none), the method's own type variables (names), the side file's line, and whether it is a class-side signature."
Class {
	#name : #OTSignature,
	#superclass : #Object,
	#instVars : [
		'selector',
		'argTypes',
		'result',
		'vars',
		'line',
		'meta',
		'owner'
	]
}

{ #category : #accessing }
OTSignature >> argTypes [
	^ argTypes
]

{ #category : #testing }
OTSignature >> isGeneric [
	^ vars notEmpty
]

{ #category : #accessing }
OTSignature >> isMeta [
	^ meta
]

{ #category : #accessing }
OTSignature >> key [
	"The dependency key of the signature: sig:Class>>selector."
	^ 'sig:' , owner name , (meta ifTrue: [' class'] ifFalse: ['']) , '>>' , selector
]

{ #category : #accessing }
OTSignature >> line [
	^ line
]

{ #category : #accessing }
OTSignature >> owner [
	^ owner
]

{ #category : #printing }
OTSignature >> printOn: aStream [
	| kw |
	kw := selector keywords.
	argTypes isEmpty ifTrue: [aStream nextPutAll: selector] ifFalse: [
		1 to: argTypes size do: [:i |
			i > 1 ifTrue: [aStream nextPutAll: ' '].
			aStream nextPutAll: (kw size >= i ifTrue: [kw at: i] ifFalse: [selector]); nextPutAll: ' <'; print: (argTypes at: i); nextPutAll: '>']].
	aStream nextPutAll: ' ^<'; print: result; nextPutAll: '>'
]

{ #category : #accessing }
OTSignature >> result [
	^ result
]

{ #category : #accessing }
OTSignature >> selector [
	^ selector
]

{ #category : #accessing }
OTSignature >> setSelector: aSymbol argTypes: anArray result: aType vars: aSet line: n meta: aBoolean owner: aClass [
	selector := aSymbol.
	argTypes := anArray.
	result := aType.
	vars := aSet.
	line := n.
	meta := aBoolean.
	owner := aClass
]

{ #category : #accessing }
OTSignature >> vars [
	^ vars
]

{ #category : #'instance creation' }
OTSignature class >> selector: aSymbol argTypes: anArray result: aType vars: aSet line: n meta: aBoolean owner: aClass [
	^ self new setSelector: aSymbol argTypes: anArray result: aType vars: aSet line: n meta: aBoolean owner: aClass
]
