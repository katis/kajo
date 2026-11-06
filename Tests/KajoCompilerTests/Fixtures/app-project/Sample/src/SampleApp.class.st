"The app kajo new made: a window with a label and a button that changes the label. open builds the window and starts the event loop; pressed is the button's action."
Class {
	#name : #SampleApp,
	#superclass : #Object,
	#classInstVars : [
		'window',
		'label',
		'button',
		'presses'
	],
	#category : #Sample
}

{ #category : #accessing }
SampleApp class >> labelText [
	^ label text
]

{ #category : #actions }
SampleApp class >> pressed [
	"The button's action: count the press and show the count."
	presses := presses + 1.
	label text: 'Pressed ' , presses printString , ' times'
]

{ #category : #opening }
SampleApp class >> open [
	"Build and show the window, then start the event loop."
	presses := 0.
	window := Window new.
	window title: 'Sample'.
	window x: 80 y: 80 width: 360 height: 220.
	label := window add: Label new.
	label x: 20 y: 60 width: 320 height: 28.
	label text: 'Hello from Kajo'.
	button := window add: Button new.
	button x: 20 y: 110 width: 200 height: 36.
	button title: 'Press me'.
	button action: [self pressed].
	window show.
	UIEventLoop start
]
