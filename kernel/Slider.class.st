"A horizontal slider over a range of Floats; its action block gets the new value."
Class {
	#name : #Slider,
	#superclass : #View,
	#instVars : [
		'action'
	],
	#category : #'Kernel-UI'
}

{ #category : #registry }
Slider class >> kind [
	^ 'slider'
]

{ #category : #accessing }
Slider >> value: aNumber [
	self set: 'value' to: aNumber asFloat
]

{ #category : #accessing }
Slider >> value [
	^ self get: 'value'
]

{ #category : #accessing }
Slider >> minimum: low maximum: high [
	self set: 'minimum' to: low asFloat; set: 'maximum' to: high asFloat
]

{ #category : #accessing }
Slider >> minimum [
	^ self get: 'minimum'
]

{ #category : #accessing }
Slider >> maximum [
	^ self get: 'maximum'
]

{ #category : #accessing }
Slider >> action: aBlock [
	action := aBlock
]

{ #category : #events }
Slider >> valueChanged: aNumber [
	action ifNotNil: [:b | b cull: aNumber cull: self]
]

{ #category : #events }
Slider >> handleEvent: anEvent [
	anEvent kind == #valueChanged ifTrue: [self valueChanged: anEvent value]
]
