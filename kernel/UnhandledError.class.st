"An Error nobody handled. Its default action reports it on the Transcript and ends the Process."
Class {
	#name : #UnhandledError,
	#superclass : #Exception,
	#instVars : [
		'exception'
	],
	#category : #'Kernel-Exceptions'
}

{ #category : #accessing }
UnhandledError >> defaultAction [
	Transcript show: 'Unhandled ' , exception printString; cr.
	exception frames do: [:f | Transcript show: '	' , f; cr].
	ProcessorScheduler terminateActive
]

{ #category : #accessing }
UnhandledError >> exception [
	^ exception
]

{ #category : #accessing }
UnhandledError >> exception: anError [
	exception := anError
]

{ #category : #accessing }
UnhandledError >> isResumable [
	^ false
]
