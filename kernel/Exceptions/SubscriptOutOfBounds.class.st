Class {
	#name : #SubscriptOutOfBounds,
	#superclass : #Error,
	#instVars : [
		'index',
		'collection'
	]
}

{ #category : #accessing }
SubscriptOutOfBounds >> index [
	^ index
]

{ #category : #accessing }
SubscriptOutOfBounds >> setIndex: anIndex collection: aCollection [
	index := anIndex.
	collection := aCollection
]

{ #category : #accessing }
SubscriptOutOfBounds class >> signalFor: anIndex in: aCollection [
	^ self new setIndex: anIndex collection: aCollection; signal: 'index ' , anIndex printString , ' out of bounds'
]
