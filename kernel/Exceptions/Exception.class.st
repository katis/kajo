"ANSI exceptions over the VM's frame walks (ADR 0009 section 5). signal looks for a handler from the signaling frame down through on:do: frames (their handler mark) and runs the handler block on top of the signaling stack, so the exception can be resumed (resume: answers from signal), returned (return: answers from on:do:), retried, passed or sent outer. Unwinding runs ensure: and ifCurtailed: blocks through Context>>resume:through:. The handler frame's third temp is its busy flag: a handler is not found again while it runs."
Class {
	#name : #Exception,
	#superclass : #Object,
	#instVars : [
		'messageText',
		'signalContext',
		'handlerContext',
		'outerContext'
	]
}

{ #category : #defaults }
Exception >> defaultAction [
	^ self subclassResponsibility
]

{ #category : #defaults }
Exception >> description [
	^ self class name asString
]

{ #category : #defaults }
Exception >> frames [
	"The methods from the signaling frame down, as 'Class>>selector' Strings."
	| out ctx |
	out := OrderedCollection new.
	ctx := self signalerContext.
	[ctx notNil and: [ctx receiver == self]] whileTrue: [ctx := ctx sender].
	[ctx notNil and: [out size < 64]] whileTrue: [
		out add: ctx method printString.
		ctx := ctx sender].
	^ out asArray
]

{ #category : #defaults }
Exception >> isResumable [
	^ true
]

{ #category : #defaults }
Exception >> messageText [
	^ messageText ifNil: [self description]
]

{ #category : #defaults }
Exception >> messageText: aString [
	messageText := aString
]

{ #category : #defaults }
Exception >> printOn: aStream [
	aStream nextPutAll: self class name.
	messageText ifNotNil: [:t | aStream nextPutAll: ': '; nextPutAll: t]
]

{ #category : #handling }
Exception >> handlerContext [
	^ handlerContext
]

{ #category : #handling }
Exception >> outer [
	"The enclosing handler's action; a resumption answers from outer."
	| value |
	self isResumable ifFalse: [^ self pass].
	outerContext := thisContext.
	value := self searchFrom: handlerContext sender.
	outerContext := nil.
	^ value
]

{ #category : #handling }
Exception >> pass [
	"The enclosing handler handles the receiver as if this one did not exist."
	handlerContext tempAt: 3 put: nil.
	^ self return: (self searchFrom: handlerContext sender)
]

{ #category : #handling }
Exception >> resume [
	^ self resume: nil
]

{ #category : #handling }
Exception >> resume: aValue [
	"Answer aValue from signal (or from outer, when it was outer that found the handler)."
	| ctx |
	self isResumable ifFalse: [^ IllegalResumeAttempt new signal: self class name , ' is not resumable'].
	handlerContext ifNotNil: [:h | h tempAt: 3 put: nil].
	outerContext isNil
		ifTrue: [ctx := signalContext]
		ifFalse: [ctx := outerContext. outerContext := nil].
	ctx return: aValue
]

{ #category : #handling }
Exception >> retry [
	"Unwind to the on:do: and run its protected block again."
	handlerContext tempAt: 3 put: nil.
	handlerContext return: self class retryMarker
]

{ #category : #handling }
Exception >> retryUsing: aBlock [
	handlerContext tempAt: 3 put: nil.
	handlerContext return: (aBlock value)
]

{ #category : #handling }
Exception >> return [
	^ self return: nil
]

{ #category : #handling }
Exception >> return: aValue [
	"Answer aValue from the on:do: whose handler is running."
	handlerContext tempAt: 3 put: nil.
	handlerContext return: aValue
]

{ #category : #handling }
Exception >> signalContext [
	^ signalContext
]

{ #category : #handling }
Exception >> signalerContext [
	^ signalContext ifNotNil: [:c | c sender]
]

{ #category : #signaling }
Exception >> evaluateHandlerIn: aContext [
	| value |
	handlerContext := aContext.
	aContext tempAt: 3 put: true.
	value := (aContext tempAt: 2) cull: self.
	^ self return: value
]

{ #category : #signaling }
Exception >> searchFrom: aContext [
	| ctx |
	ctx := aContext ifNotNil: [:c | c findNextHandlerContextStarting].
	[ctx isNil] whileFalse: [
		((ctx tempAt: 3) isNil and: [(ctx tempAt: 1) handles: self]) ifTrue: [^ self evaluateHandlerIn: ctx].
		ctx := ctx sender ifNotNil: [:s | s findNextHandlerContextStarting]].
	^ self defaultAction
]

{ #category : #signaling }
Exception >> signal [
	signalContext := thisContext.
	^ self searchFrom: thisContext sender
]

{ #category : #signaling }
Exception >> signal: aString [
	messageText := aString.
	^ self signal
]

{ #category : #accessing }
Exception class >> , anExceptionClass [
	^ ExceptionSet with: self with: anExceptionClass
]

{ #category : #accessing }
Exception class >> handles: anException [
	^ anException isKindOf: self
]

{ #category : #accessing }
Exception class >> new [
	^ self basicNew initialize
]

{ #category : #accessing }
Exception class >> retryMarker [
	"What on:do:'s loop takes as 'run the protected block again' (Exception>>retry)."
	^ ExceptionSet
]

{ #category : #accessing }
Exception class >> signal [
	^ self new signal
]

{ #category : #accessing }
Exception class >> signal: aString [
	^ self new signal: aString
]
