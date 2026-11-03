Class {
	#name : #KeyNotFound,
	#superclass : #NotFound,
	#instVars : [
		'key'
	],
	#category : #'Kernel-Exceptions'
}

{ #category : #accessing }
KeyNotFound >> key [
	^ key
]

{ #category : #accessing }
KeyNotFound >> key: anObject [
	key := anObject
]
