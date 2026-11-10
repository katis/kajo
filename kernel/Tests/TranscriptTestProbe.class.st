"An object whose printOn: fails (TranscriptTest: the review fixes, item 7)."
Class {
	#name : #TranscriptTestProbe,
	#superclass : #Object
}

{ #category : #printing }
TranscriptTestProbe >> printOn: aStream [
	self error: 'TranscriptTestProbe cannot print itself'
]
