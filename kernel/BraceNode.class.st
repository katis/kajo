Class {
	#name : #BraceNode,
	#superclass : #ParseNode,
	#instVars : [
		'elements'
	],
	#category : #'Kernel-Compiler'
}

{ #category : #accessing }
BraceNode class >> elements: anArray line: n [
	^ self new setElements: anArray; line: n; yourself
]

{ #category : #accessing }
BraceNode >> setElements: anArray [
	elements := anArray
]

{ #category : #accessing }
BraceNode >> elements [
	^ elements
]
