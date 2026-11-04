"A line of text."
Class {
	#name : #Label,
	#superclass : #View,
	#category : #'Kernel-UI'
}

{ #category : #registry }
Label class >> kind [
	^ 'label'
]

{ #category : #accessing }
Label >> text: aString [
	self set: 'text' to: aString
]

{ #category : #accessing }
Label >> text [
	^ self get: 'text'
]
