"A window's toolbar (module 9c): items with an id and a title; choosing one runs the action with its id. Window>>toolbar: puts it on a window."
Class {
	#name : #Toolbar,
	#superclass : #View,
	#instVars : [
		'action'
	],
	#category : #'Kernel-UI'
}

{ #category : #accessing }
Toolbar >> action: aBlock [
	action := aBlock
]

{ #category : #accessing }
Toolbar >> addItem: anId title: aString [
	self call: 'addItem' with: {anId. aString}
]

{ #category : #events }
Toolbar >> choose: anId [
	action ifNotNil: [:b | b cull: anId]
]

{ #category : #events }
Toolbar >> handleEvent: anEvent [
	anEvent kind == #menu ifTrue: [self choose: anEvent value]
]

{ #category : #registry }
Toolbar class >> kind [
	^ 'toolbar'
]
