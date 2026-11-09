Class {
	#name : #LiteralNode,
	#superclass : #ParseNode,
	#instVars : [
		'value'
	]
}

{ #category : #accessing }
LiteralNode >> setValue: anObject [
	value := anObject
]

{ #category : #accessing }
LiteralNode >> value [
	^ value
]

{ #category : #accessing }
LiteralNode class >> value: anObject line: n [
	^ self new setValue: anObject; line: n; yourself
]
