"ANSI exceptions over the VM's frame walks (ADR 0009 section 5). signal looks for a handler from the signaling frame down through on:do: frames (their handler mark) and runs the handler block on top of the signaling stack, so the exception can be resumed (resume: answers from signal), returned (return: answers from on:do:), retried, passed or sent outer. Unwinding runs ensure: and ifCurtailed: blocks through Context>>resume:through:. The handler frame's third temp is its busy flag: a handler is not found again while it runs."
Class {
	#name : #Exception,
	#superclass : #Object,
	#instVars : [
		'messageText <String | Nil>',
		'signalContext',
		'handlerContext',
		'outerContext'
	],
	#classVars : [
		'RetryMarker'
	]
}

{ #category : #defaults }
Exception >> defaultAction ^<Dynamic> [
	^ self subclassResponsibility
]

{ #category : #defaults }
Exception >> description ^<String> [
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
Exception >> isResumable ^<Boolean> [
	^ true
]

{ #category : #defaults }
Exception >> messageText ^<String> [
	^ messageText ifNil: [self description]
]

{ #category : #defaults }
Exception >> messageText: aString <String> ^<Self> [
	messageText := aString
]

{ #category : #defaults }
Exception >> printOn: aStream <WriteStream> ^<Self> [
	aStream nextPutAll: self class name.
	messageText ifNotNil: [:t | aStream nextPutAll: ': '; nextPutAll: t]
]

{ #category : #handling }
Exception >> handlerContext [
	^ handlerContext
]

{ #category : #handling }
Exception >> outer ^<Dynamic> [
	"The enclosing handler's action; a resumption answers from outer, and the handler that sent outer is the active one again (the review fixes, item 9: return:, retry, resume: and falling off it act on its on:do:, and it stays busy). A resumption returns from outerSearch, so the restore below runs; a return or a retry by the enclosing handler unwinds past it."
	| saved value |
	self isResumable ifFalse: [^ self pass].
	saved := handlerContext.
	value := self outerSearch.
	outerContext := nil.
	handlerContext := saved.
	saved tempAt: 3 put: true.
	^ value
]

{ #category : #handling }
Exception >> outerSearch [
	"The search outer starts: a resumption by the enclosing handler answers here (resume: returns from this frame)."
	outerContext := thisContext.
	^ self searchFrom: handlerContext sender
]

{ #category : #handling }
Exception >> pass ^<Dynamic> [
	"The enclosing handler handles the receiver as if this one did not exist. With none, the default action's value resumes a resumable exception at its signal (the review fixes, item 9, ANSI's rule) and is returned from this on:do: otherwise. An enclosing handler that resumes or returns never comes back here."
	| value |
	handlerContext tempAt: 3 put: nil.
	value := self searchFrom: handlerContext sender.
	self isResumable ifTrue: [^ self resume: value].
	^ self return: value
]

{ #category : #handling }
Exception >> receiver [
	"The receiver of the method that signalled: the first frame below the signal that is not the exception's own (as frames skips them). Nil before a signal. BlockClosure>>ifError: hands it to its block."
	| ctx |
	ctx := self signalerContext.
	[ctx notNil and: [ctx receiver == self]] whileTrue: [ctx := ctx sender].
	^ ctx ifNotNil: [:c | c receiver]
]

{ #category : #handling }
Exception >> resume ^<Dynamic> [
	^ self resume: nil
]

{ #category : #handling }
Exception >> resume: aValue <Object> ^<Dynamic> [
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
Exception >> retry ^<Dynamic> [
	"Unwind to the on:do: and run its protected block again."
	handlerContext tempAt: 3 put: nil.
	handlerContext return: Exception retryMarker
]

{ #category : #handling }
Exception >> retryUsing: aBlock <[^Dynamic]> ^<Dynamic> [
	"Unwind to the on:do: and run aBlock in place of its protected block, under the same handler (the review fixes, item 9: aBlock ran before the unwinding, inside the busy handler). The on:do: frame (the handler frame's sender) takes aBlock in its fifth temp."
	handlerContext tempAt: 3 put: nil.
	handlerContext sender tempAt: 5 put: aBlock.
	handlerContext return: Exception retryMarker
]

{ #category : #handling }
Exception >> return ^<Dynamic> [
	^ self return: nil
]

{ #category : #handling }
Exception >> return: aValue <Object> ^<Dynamic> [
	"Answer aValue from the on:do: whose handler is running."
	handlerContext tempAt: 3 put: nil.
	handlerContext return: aValue
]

{ #category : #handling }
Exception >> signalContext [
	^ signalContext
]

{ #category : #handling }
Exception >> signalerContext ^<Context | Nil> [
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
Exception >> signal ^<Dynamic> [
	signalContext := thisContext.
	^ self searchFrom: thisContext sender
]

{ #category : #signaling }
Exception >> signal: aString <String> ^<Dynamic> [
	messageText := aString.
	^ self signal
]

{ #category : #accessing }
Exception class >> , anExceptionClass <Exception class | ExceptionSet> ^<ExceptionSet> [
	^ ExceptionSet with: self with: anExceptionClass
]

{ #category : #accessing }
Exception class >> handles: anException <Exception> ^<Boolean> [
	^ anException isKindOf: self
]

{ #category : #accessing }
Exception class >> initialize [
	"The retry marker, made once at the image build (the review fixes, item 8)."
	RetryMarker isNil ifTrue: [RetryMarker := Object new]
]

{ #category : #accessing }
Exception class >> new [
	^ self basicNew initialize
]

{ #category : #accessing }
Exception class >> retryMarker [
	"What on:do:'s loop takes as 'run the protected block again' (Exception>>retry): a private object nothing else answers (the review fixes, item 8: it was the class ExceptionSet, so a protected block or handler that answered that class retried forever)."
	^ RetryMarker ifNil: [self initialize. RetryMarker]
]

{ #category : #accessing }
Exception class >> signal ^<Dynamic> [
	^ self new signal
]

{ #category : #accessing }
Exception class >> signal: aString <String> ^<Dynamic> [
	^ self new signal: aString
]
