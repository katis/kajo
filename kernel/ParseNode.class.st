"A node of a method's tree (the Smalltalk compiler's)."
Class {
	#name : #ParseNode,
	#superclass : #Object,
	#instVars : [
		'line'
	],
	#category : #'Kernel-Compiler'
}

{ #category : #accessing }
ParseNode >> line [
	^ line
]

{ #category : #accessing }
ParseNode >> line: anInteger [
	line := anInteger
]
