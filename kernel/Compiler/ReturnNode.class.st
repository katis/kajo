Class {
	#name : #ReturnNode,
	#superclass : #ParseNode,
	#instVars : [
		'value'
	]
}

{ #category : #accessing }
ReturnNode >> setValue: aNode [
	value := aNode
]

{ #category : #accessing }
ReturnNode >> value [
	^ value
]

{ #category : #accessing }
ReturnNode class >> value: aNode line: n [
	^ self new setValue: aNode; line: n; yourself
]
