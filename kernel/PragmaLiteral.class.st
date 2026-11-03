"A pragma the Smalltalk compiler made (it becomes a Pragma when installed)."
Class {
	#name : #PragmaLiteral,
	#superclass : #Object,
	#instVars : [
		'selector',
		'arguments'
	],
	#category : #'Kernel-Compiler'
}

{ #category : #accessing }
PragmaLiteral class >> selector: s arguments: a [
	^ self new setSelector: s arguments: a
]

{ #category : #accessing }
PragmaLiteral >> setSelector: s arguments: a [
	selector := s.
	arguments := a
]

{ #category : #accessing }
PragmaLiteral >> selector [
	^ selector
]

{ #category : #accessing }
PragmaLiteral >> arguments [
	^ arguments
]
