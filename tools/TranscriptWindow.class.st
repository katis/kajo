"The transcript's window (module 9c): the transcript lines of every connected target, appended as they arrive."
Class {
	#name : #TranscriptWindow,
	#superclass : #ToolWindow,
	#instVars : [
		'textView'
	],
	#category : #'Tools-Windows'
}

{ #category : #building }
TranscriptWindow >> build [
	self makeWindow: 'Transcript'.
	textView := self textAt: {0. 0. 600. 300} editable: false.
	textView autoresize: 'width height'.
	model lines do: [:l | textView appendLine: l]
]

{ #category : #building }
TranscriptWindow >> defaultFrame [
	^ {40. 700. 600. 300}
]

{ #category : #updating }
TranscriptWindow >> update: anAspect [
	anAspect == #line ifTrue: [textView appendLine: model lastLine]
]
