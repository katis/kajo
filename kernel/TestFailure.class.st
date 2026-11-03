"An assertion that did not hold. Not an Error: on: Error do: in the code under test does not catch it."
Class {
	#name : #TestFailure,
	#superclass : #Exception,
	#category : #SUnit
}

{ #category : #accessing }
TestFailure >> isResumable [
	^ false
]

{ #category : #accessing }
TestFailure >> defaultAction [
	^ UnhandledError new exception: self; signal
]
