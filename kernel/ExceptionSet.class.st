"Several exception classes for one handler: on: ZeroDivide, MessageNotUnderstood do: ..."
Class {
	#name : #ExceptionSet,
	#superclass : #Object,
	#instVars : [
		'exceptions'
	],
	#category : #'Kernel-Exceptions'
}

{ #category : #accessing }
ExceptionSet class >> with: a with: b [
	^ self basicNew setExceptions: (OrderedCollection with: a with: b)
]

{ #category : #accessing }
ExceptionSet >> setExceptions: aCollection [
	exceptions := aCollection
]

{ #category : #accessing }
ExceptionSet >> , anExceptionClass [
	exceptions add: anExceptionClass
]

{ #category : #accessing }
ExceptionSet >> handles: anException [
	^ exceptions anySatisfy: [:e | e handles: anException]
]
