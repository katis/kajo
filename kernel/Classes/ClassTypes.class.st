"A class's types as written in its definition (Types 1, docs/modules/types-1.md): its type parameters (Strings, #typeParameters), what it gives its superclass's (a type's text, #superclassType, or nil) and its instance variables' types (instance variable name, a Symbol, to the type's text, written after the name in #instVars). Text only: nothing checks it and the VM never sees it. Smalltalk keeps one per class that has any, in a table of its own that a release image's build does not fill (question 3); the Tonel writer writes it back."
Class {
	#name : #ClassTypes,
	#superclass : #Object,
	#instVars : [
		'typeParameters',
		'superclassType',
		'instVarTypes'
	]
}

{ #category : #accessing }
ClassTypes >> instVarTypes [
	^ instVarTypes ifNil: [instVarTypes := IdentityDictionary new]
]

{ #category : #accessing }
ClassTypes >> isEmpty [
	^ self typeParameters isEmpty and: [superclassType isNil and: [self instVarTypes isEmpty]]
]

{ #category : #accessing }
ClassTypes >> keepOnly: names [
	"Forget the types of instance variables not among names (a redefinition removed them)."
	(self instVarTypes keys reject: [:n | names includes: n]) do: [:n | instVarTypes removeKey: n]
]

{ #category : #accessing }
ClassTypes >> superclassType [
	^ superclassType
]

{ #category : #accessing }
ClassTypes >> superclassType: aStringOrNil [
	superclassType := aStringOrNil
]

{ #category : #accessing }
ClassTypes >> type: aString of: aName [
	self instVarTypes at: aName asSymbol put: aString
]

{ #category : #accessing }
ClassTypes >> typeOf: aName [
	"The type's text of the instance variable aName, or nil."
	^ self instVarTypes at: aName asSymbol ifAbsent: [nil]
]

{ #category : #accessing }
ClassTypes >> typeParameters [
	^ typeParameters ifNil: [#()]
]

{ #category : #accessing }
ClassTypes >> typeParameters: anArray [
	typeParameters := anArray
]
