"One signature of a selector as the checker reads it: the argument types, the result type (Dynamic when none is written), the method variables it declares (names, :X), whether it is the class side's, the class it belongs to (owner, the class itself, not its metaclass) and where it comes from (kind: #method, a typed method's pattern; #signature, a signature without a method, docs/modules/types-2.md; #protocol, a protocol made by code; #overlay, one a test or a tool added to the table). An overloaded pattern (<Integer; Number>) is one TypeSignature per alternative, in order."
Class {
	#name : #TypeSignature,
	#superclass : #Object,
	#instVars : [
		'selector',
		'argTypes',
		'result',
		'vars',
		'meta',
		'owner',
		'kind'
	]
}

{ #category : #accessing }
TypeSignature >> argTypes [
	^ argTypes
]

{ #category : #accessing }
TypeSignature >> isMeta [
	^ meta
]

{ #category : #accessing }
TypeSignature >> key [
	"The dependency key of the signature: sig:Class>>selector or sig:Class class>>selector (a protocol's: its name)."
	^ 'sig:' , (owner isString ifTrue: [owner] ifFalse: [owner name]) , (meta ifTrue: [' class'] ifFalse: ['']) , '>>' , selector
]

{ #category : #accessing }
TypeSignature >> kind [
	^ kind
]

{ #category : #accessing }
TypeSignature >> owner [
	^ owner
]

{ #category : #accessing }
TypeSignature >> result [
	^ result
]

{ #category : #accessing }
TypeSignature >> selector [
	^ selector
]

{ #category : #accessing }
TypeSignature >> setSelector: aSymbol argTypes: anArray result: aType vars: aSet meta: aBoolean owner: aClassOrName kind: aKind [
	selector := aSymbol.
	argTypes := anArray.
	result := aType.
	vars := aSet.
	meta := aBoolean.
	owner := aClassOrName.
	kind := aKind
]

{ #category : #accessing }
TypeSignature >> vars [
	^ vars
]

{ #category : #printing }
TypeSignature >> printOn: aStream [
	| kw |
	kw := selector keywords.
	argTypes isEmpty ifTrue: [aStream nextPutAll: selector] ifFalse: [
		1 to: argTypes size do: [:i |
			i > 1 ifTrue: [aStream nextPutAll: ' '].
			aStream nextPutAll: (kw size >= i ifTrue: [kw at: i] ifFalse: [selector]); nextPutAll: ' <'; print: (argTypes at: i); nextPutAll: '>']].
	aStream nextPutAll: ' ^<'; print: result; nextPutAll: '>'
]

{ #category : #testing }
TypeSignature >> isGeneric [
	^ vars notEmpty
]

{ #category : #'instance creation' }
TypeSignature class >> selector: aSymbol argTypes: anArray result: aType vars: aSet meta: aBoolean owner: aClassOrName kind: aKind [
	^ self new setSelector: aSymbol argTypes: anArray result: aType vars: aSet meta: aBoolean owner: aClassOrName kind: aKind
]
