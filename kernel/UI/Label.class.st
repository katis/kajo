"A line of text."
Class {
	#name : #Label,
	#superclass : #View
}

{ #category : #accessing }
Label >> text [
	^ self get: 'text'
]

{ #category : #accessing }
Label >> text: aString [
	self set: 'text' to: aString
]

{ #category : #registry }
Label class >> kind [
	^ 'label'
]
