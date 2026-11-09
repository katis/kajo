"A push button: its action block runs in the event loop's Process on the main thread, synchronously in the run-loop turn that delivered the click."
Class {
	#name : #Button,
	#superclass : #View,
	#instVars : [
		'action'
	]
}

{ #category : #accessing }
Button >> action: aBlock [
	action := aBlock
]

{ #category : #accessing }
Button >> title [
	^ self get: 'title'
]

{ #category : #accessing }
Button >> title: aString [
	self set: 'title' to: aString
]

{ #category : #events }
Button >> click [
	"What a press does (the event loop sends it; tests may too)."
	action ifNotNil: [:b | b cull: self]
]

{ #category : #events }
Button >> handleEvent: anEvent [
	anEvent kind == #click ifTrue: [self click]
]

{ #category : #registry }
Button class >> kind [
	^ 'button'
]
