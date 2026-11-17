"A Strongtalk-style type as written in a method's pattern or a class definition (Types 1, docs/modules/types-1.md), kept in the tree with its source range and never read by code generation: the bootstrap compiler's TypeNode in Smalltalk. kind is #name (name and parts, its arguments: Integer, Array[E]), #variable (name: :X, a method variable declared where it first appears), #block (parts the argument types, result: [A, ^R]), #union (parts: A | B), #class (parts the one type: X class) or #alternatives (parts, one per signature of an overloaded method). A parenthesized type is its inner type."
Class {
	#name : #TypeNode,
	#superclass : #ParseNode,
	#instVars : [
		'kind',
		'name',
		'parts',
		'result'
	]
}

{ #category : #accessing }
TypeNode >> declaresVariable [
	"Whether a method variable is declared in it (:X)."
	kind == #variable ifTrue: [^ true].
	(result notNil and: [result declaresVariable]) ifTrue: [^ true].
	^ parts anySatisfy: [:p | p declaresVariable]
]

{ #category : #accessing }
TypeNode >> description [
	"The form both compilers' tests compare (the bootstrap's TypeNode.description): the kind, the range and the parts."
	| s |
	s := WriteStream on: String new.
	self printDescriptionOn: s.
	^ s contents
]

{ #category : #accessing }
TypeNode >> kind [
	^ kind
]

{ #category : #accessing }
TypeNode >> name [
	^ name
]

{ #category : #accessing }
TypeNode >> parts [
	^ parts
]

{ #category : #accessing }
TypeNode >> printDescriptionOn: aStream [
	| range |
	range := [aStream print: sourceStart; nextPutAll: ' '; print: sourceEnd].
	aStream nextPut: $(.
	kind == #name ifTrue: [aStream nextPutAll: 'name '; nextPutAll: name; nextPutAll: ' '. range value].
	kind == #variable ifTrue: [aStream nextPutAll: 'var '; nextPutAll: name; nextPutAll: ' '. range value].
	kind == #block ifTrue: [aStream nextPutAll: 'block '. range value].
	kind == #union ifTrue: [aStream nextPutAll: 'union '. range value].
	kind == #class ifTrue: [aStream nextPutAll: 'class '. range value].
	kind == #alternatives ifTrue: [aStream nextPutAll: 'alt '. range value].
	parts do: [:p | aStream nextPutAll: ' '. p printDescriptionOn: aStream].
	result ifNotNil: [:r | aStream nextPutAll: ' ^'. r printDescriptionOn: aStream].
	aStream nextPut: $)
]

{ #category : #accessing }
TypeNode >> result [
	^ result
]

{ #category : #initialization }
TypeNode >> setKind: aSymbol name: aString parts: anArray result: aTypeNodeOrNil [
	kind := aSymbol.
	name := aString.
	parts := anArray.
	result := aTypeNodeOrNil
]

{ #category : #'instance creation' }
TypeNode class >> kind: aSymbol name: aString parts: anArray result: aTypeNodeOrNil start: start end: end [
	^ self new setKind: aSymbol name: aString parts: anArray result: aTypeNodeOrNil; sourceStart: start end: end; yourself
]
