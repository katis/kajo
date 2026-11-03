"A FIFO between Processes: next waits until there is an item."
Class {
	#name : #SharedQueue,
	#superclass : #Object,
	#instVars : [
		'monitor',
		'items'
	],
	#category : #'Kernel-Processes'
}

{ #category : #accessing }
SharedQueue class >> new [
	^ self basicNew setUp
]

{ #category : #accessing }
SharedQueue >> setUp [
	monitor := Monitor new.
	items := OrderedCollection new
]

{ #category : #accessing }
SharedQueue >> nextPut: anObject [
	monitor critical: [items addLast: anObject. monitor signal].
	^ anObject
]

{ #category : #accessing }
SharedQueue >> next [
	^ monitor critical: [
		[items isEmpty] whileTrue: [monitor wait].
		items removeFirst]
]

{ #category : #accessing }
SharedQueue >> nextOrNil [
	^ monitor critical: [items isEmpty ifTrue: [nil] ifFalse: [items removeFirst]]
]

{ #category : #accessing }
SharedQueue >> isEmpty [
	^ monitor critical: [items isEmpty]
]

{ #category : #accessing }
SharedQueue >> size [
	^ monitor critical: [items size]
]
