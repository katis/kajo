"binarytrees: Kajo's alloc kernel in Smalltalk. A node of a binary tree; a leaf has no children."
Class {
	#name : #Node,
	#superclass : #Object,
	#instVars : [ 'left', 'right' ],
	#category : #Bench
}

{ #category : #bench }
Node >> build: depth [
	depth > 0 ifTrue: [
		left := Node basicNew build: depth - 1.
		right := Node basicNew build: depth - 1]
]

{ #category : #bench }
Node >> check [
	left isNil ifTrue: [^ 1].
	^ left check + right check + 1
]
