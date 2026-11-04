"A top-level view: a window per Window on macOS, the screen's one window on iOS (the shell gives each Window a full-screen container). Holds its subviews, so they live while it does."
Class {
	#name : #Window,
	#superclass : #View,
	#instVars : [
		'closeAction',
		'closed'
	],
	#category : #'Kernel-UI'
}

{ #category : #accessing }
Window >> close [
	"Close the native window; the wrapper stays (its handle is released when it is collected)."
	closed := true.
	self call: 'close' with: #()
]

{ #category : #accessing }
Window >> isClosed [
	^ closed == true
]

{ #category : #accessing }
Window >> onClose: aBlock [
	closeAction := aBlock
]

{ #category : #accessing }
Window >> show [
	closed := false.
	self call: 'show' with: #()
]

{ #category : #accessing }
Window >> title [
	^ self get: 'title'
]

{ #category : #accessing }
Window >> title: aString [
	self set: 'title' to: aString
]

{ #category : #events }
Window >> handleEvent: anEvent [
	anEvent kind == #close ifTrue: [
		closed := true.
		closeAction ifNotNil: [:b | b cull: self]]
]

{ #category : #registry }
Window class >> kind [
	^ 'window'
]
