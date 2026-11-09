"An Error nobody handled. Its default action stops the Process for the debugger in a development image whose host said a debugger can still come (Debugger stopsErrors: the development answers), with or without a client, unless Debugger stopCap error stops stand; otherwise, and always in a release image or a batch host, it reports the error on the Transcript and ends the Process."
Class {
	#name : #UnhandledError,
	#superclass : #Exception,
	#instVars : [
		'exception'
	]
}

{ #category : #accessing }
UnhandledError >> defaultAction [
	"In a development image whose host said a debugger can still come, the Process stops for the debugger (module 9b, the development answers) and what a client does decides the answer, unless the stops stand at their cap; otherwise, and always in a release image or a batch host, the error is reported on the Transcript and the Process ends."
	Debugger stopsErrors ifTrue: [^ Debugger stop: exception ifFull: [self reportAndEnd]].
	^ self reportAndEnd
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

{ #category : #accessing }
UnhandledError >> reportAndEnd [
	Transcript showLine: 'Unhandled ' , exception printString.
	exception frames do: [:f | Transcript showLine: '	' , f].
	ProcessorScheduler terminateActive
]
