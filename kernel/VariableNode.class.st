"binding: #self #super #thisContext #local (target a TempVariable) #instance (target a slot index) #global (target a class)."
Class {
	#name : #VariableNode,
	#superclass : #ParseNode,
	#instVars : [
		'name',
		'binding',
		'target'
	],
	#category : #'Kernel-Compiler'
}

{ #category : #accessing }
VariableNode >> bind: aSymbol to: anObject [
	binding := aSymbol.
	target := anObject
]

{ #category : #accessing }
VariableNode >> binding [
	^ binding
]

{ #category : #accessing }
VariableNode >> name [
	^ name
]

{ #category : #accessing }
VariableNode >> setName: aString [
	name := aString
]

{ #category : #accessing }
VariableNode >> target [
	^ target
]

{ #category : #accessing }
VariableNode class >> named: aString line: n [
	^ self new setName: aString; line: n; yourself
]
