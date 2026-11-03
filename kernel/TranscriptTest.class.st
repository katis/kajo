Class {
	#name : #TranscriptTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
TranscriptTest >> testShowAndContents [
	Transcript flush.
	Transcript show: 'abc'; show: 42; print: 'q'.
	self assert: Transcript contents = 'abc42''q'''.
	Transcript cr.
	self assert: Transcript contents isEmpty
]
