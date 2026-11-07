"What the development answers' Processes run: compute sends a message nothing defines until a client defines it."
Class {
	#name : #AnswersSample,
	#superclass : #Object,
	#category : #'Answers-Tests'
}

{ #category : #computing }
AnswersSample >> compute [
	^ self missingPart + 1
]

{ #category : #computing }
AnswersSample >> callGuarded [
	^ self guarded
]

{ #category : #computing }
AnswersSample >> guarded [
	"An ensure: block that never ends: an unwinding through it is cut off at the bound."
	^ [self missingPart] ensure: [Semaphore new wait]
]
