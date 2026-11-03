"An error. Unhandled, it signals UnhandledError, whose default action reports it on the Transcript and ends the Process."
Class {
	#name : #Error,
	#superclass : #Exception,
	#category : #'Kernel-Exceptions'
}

{ #category : #accessing }
Error >> isResumable [
	^ false
]

{ #category : #accessing }
Error >> defaultAction [
	^ UnhandledError new exception: self; signal
]
