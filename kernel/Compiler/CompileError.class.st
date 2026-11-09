"A source the compiler refuses: the message and the line."
Class {
	#name : #CompileError,
	#superclass : #Error,
	#instVars : [
		'line'
	]
}

{ #category : #accessing }
CompileError >> line [
	^ line
]

{ #category : #accessing }
CompileError >> line: anInteger [
	line := anInteger
]

{ #category : #accessing }
CompileError >> messageText [
	^ 'line ' , line printString , ': ' , super messageText
]
