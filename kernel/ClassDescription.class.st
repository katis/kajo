"The common superclass of Class and Metaclass."
Class {
	#name : #ClassDescription,
	#superclass : #Behavior,
	#category : #'Kernel-Classes'
}

{ #category : #accessing }
ClassDescription >> category [
	^ Smalltalk categoryOf: self theNonMetaClass
]

{ #category : #accessing }
ClassDescription >> comment [
	"The class comment, a String ('' when none; module 8e)."
	^ (Smalltalk definitionOf: self theNonMetaClass) ifNil: [''] ifNotNil: [:d | d comment ifNil: ['']]
]

{ #category : #accessing }
ClassDescription >> comment: aString [
	(Smalltalk definitionOf: self theNonMetaClass) ifNotNil: [:d | d comment: aString]
]

{ #category : #accessing }
ClassDescription >> category: aStringOrSymbol [
	(Smalltalk definitionOf: self theNonMetaClass) ifNotNil: [:d | d category: aStringOrSymbol asSymbol]
]
