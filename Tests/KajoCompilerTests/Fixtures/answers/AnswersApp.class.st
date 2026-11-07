"An app whose open fails (the development answers): open sends a message nothing defines; in a development build the open Process stops and serving starts anyway."
Class {
	#name : #AnswersApp,
	#superclass : #Object,
	#classInstVars : [
		'started'
	],
	#category : #'Answers-Tests'
}

{ #category : #opening }
AnswersApp class >> open [
	started := self startUpValue.
	^ started
]

{ #category : #accessing }
AnswersApp class >> started [
	^ started
]
