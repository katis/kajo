"The common superclass of Class and Metaclass."
Class {
	#name : #ClassDescription,
	#superclass : #Behavior
}

{ #category : #accessing }
ClassDescription >> comment [
	"The class comment, a String ('' when none; module 8e)."
	^ (Smalltalk definitionOf: self theNonMetaClass) ifNil: [''] ifNotNil: [:d | d comment ifNil: ['']]
]

{ #category : #accessing }
ClassDescription >> comment: aString [
	(Smalltalk definitionOf: self theNonMetaClass) ifNotNil: [:d | d comment: aString]
]

{ #category : #'instance variables' }
ClassDescription >> addInstVarName: aString [
	(self instVarNames includes: aString asSymbol) ifTrue: [^ self].
	^ self setInstVarNames: (self instVarNames asArray copyWith: aString asSymbol)
]

{ #category : #'instance variables' }
ClassDescription >> instVarNames [
	"This class's own instance variable names (its class side's own class-side ones for a metaclass), Symbols."
	| d |
	d := Smalltalk definitionOf: self theNonMetaClass.
	d isNil ifTrue: [^ #()].
	^ self isMeta ifTrue: [d classInstVarNames] ifFalse: [d instVarNames]
]

{ #category : #'instance variables' }
ClassDescription >> instanceVariableNames: aString [
	"Make aString's names (separated by blanks) this class's own instance variables (class-side ones for a metaclass), keeping every value by name (module 8e)."
	^ self setInstVarNames: (aString substrings collect: [:n | n asSymbol])
]

{ #category : #'instance variables' }
ClassDescription >> removeInstVarName: aString [
	(self instVarNames includes: aString asSymbol) ifFalse: [^ ClassDefinitionError new signal: self name , ' has no instance variable ' , aString].
	^ self setInstVarNames: (self instVarNames asArray reject: [:n | n = aString asSymbol])
]

{ #category : #'instance variables' }
ClassDescription >> setInstVarNames: anArray [
	| c |
	c := self theNonMetaClass.
	^ self isMeta
		ifTrue: [ClassBuilder redefine: c instanceVariableNames: c instVarNames classVariableNames: c classVarNames classInstanceVariableNames: anArray]
		ifFalse: [ClassBuilder redefine: c instanceVariableNames: anArray classVariableNames: c classVarNames classInstanceVariableNames: c class instVarNames]
]
