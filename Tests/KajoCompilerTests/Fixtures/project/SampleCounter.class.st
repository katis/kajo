"A counter for the development protocol's tests (module 9b)."
Class {
	#name : #SampleCounter,
	#superclass : #Object,
	#instVars : [
		'count'
	],
	#category : #'Sample-Core'
}

{ #category : #accessing }
SampleCounter >> count [
	^ count ifNil: [0]
]

{ #category : #accessing }
SampleCounter >> increment [
	<author: #'agent:fixture'>
	count := self count + 1
]
