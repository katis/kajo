"A resumable warning; unhandled, it is shown on the Transcript and answers nil."
Class {
	#name : #Warning,
	#superclass : #Exception
}

{ #category : #accessing }
Warning >> defaultAction [
	Transcript show: 'Warning: ' , self messageText; cr.
	^ nil
]
