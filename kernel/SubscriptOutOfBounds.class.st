Class {
	#name : #SubscriptOutOfBounds,
	#superclass : #Error,
	#instVars : [
		'index',
		'collection'
	],
	#category : #'Kernel-Exceptions'
}

{ #category : #accessing }
SubscriptOutOfBounds class >> signalFor: anIndex in: aCollection [
	^ self new setIndex: anIndex collection: aCollection; signal: 'index ' , anIndex printString , ' out of bounds'
]

{ #category : #accessing }
SubscriptOutOfBounds >> setIndex: anIndex collection: aCollection [
	index := anIndex.
	collection := aCollection
]

{ #category : #accessing }
SubscriptOutOfBounds >> index [
	^ index
]
