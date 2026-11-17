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

{ #category : #accessing }
CompileError >> reason [
	"The message without its line (Types 1: a Tonel reader puts the key it read before it)."
	^ super messageText
]
