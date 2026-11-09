Class {
	#name : #AssignmentNode,
	#superclass : #ParseNode,
	#instVars : [
		'variable',
		'value'
	]
}

{ #category : #accessing }
AssignmentNode >> setVariable: aVariableNode value: aNode [
	variable := aVariableNode.
	value := aNode
]

{ #category : #accessing }
AssignmentNode >> value [
	^ value
]

{ #category : #accessing }
AssignmentNode >> variable [
	^ variable
]

{ #category : #accessing }
AssignmentNode class >> variable: aVariableNode value: aNode line: n [
	^ self new setVariable: aVariableNode value: aNode; line: n; yourself
]
