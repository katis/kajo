"Methods to stop, step and restart in the development protocol's tests (module 9b); result keeps what a resumed doit answered."
Class {
	#name : #SampleDebug,
	#superclass : #Object,
	#classInstVars : [
		'result'
	],
	#category : #'Sample-Core'
}

{ #category : #samples }
SampleDebug >> failing: x [
	^ self error: 'boom'
]

{ #category : #samples }
SampleDebug >> first: n [
	^ (self helper: n) + 1
]

{ #category : #samples }
SampleDebug >> helper: n [
	^ n
]

{ #category : #samples }
SampleDebug >> second: n [
	^ n * 2
]

{ #category : #samples }
SampleDebug >> stepped: n [
	| a |
	self notYetDefined.
	a := self first: n.
	a := self second: a.
	^ a - 3
]

{ #category : #accessing }
SampleDebug class >> result [
	^ result
]

{ #category : #accessing }
SampleDebug class >> result: anObject [
	result := anObject
]
