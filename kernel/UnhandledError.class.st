"An Error nobody handled. Its default action stops the Process for the debugger when the development protocol serves (module 9b), else reports it on the Transcript and ends the Process."
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
	"In a development image whose development protocol serves, the Process stops for the debugger (module 9b) and what a client does decides the answer; otherwise, and always in a release image, the error is reported on the Transcript and the Process ends."
	Debugger isEnabled ifTrue: [^ Debugger stop: exception].
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
