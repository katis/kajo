"A message: what doesNotUnderstand: receives."
Class {
	#name : #Message,
	#superclass : #Object,
	#instVars : [
		'selector',
		'arguments'
	],
	#category : #'Kernel-Methods'
}

{ #category : #accessing }
Message class >> selector: aSymbol arguments: anArray [
	^ self new setSelector: aSymbol arguments: anArray
]

{ #category : #accessing }
Message >> setSelector: aSymbol arguments: anArray [
	selector := aSymbol.
	arguments := anArray
]

{ #category : #accessing }
Message >> selector [
	^ selector
]

{ #category : #accessing }
Message >> arguments [
	^ arguments
]

{ #category : #accessing }
Message >> sendTo: anObject [
	^ anObject perform: selector withArguments: arguments
]

{ #category : #accessing }
Message >> printOn: aStream [
	aStream nextPutAll: selector printString.
	arguments isEmpty ifFalse: [aStream nextPutAll: ' with '; print: arguments]
]
