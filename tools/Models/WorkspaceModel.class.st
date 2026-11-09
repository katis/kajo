"A workspace's model (module 9c): evaluate a selection (do it), print it, inspect it, as a doit in the target, self the object under a handle (an inspector's pane) or a frame of a stopped Process (the debugger's pane) or nil. The answer is the target's description (printString, class, handle); print it hands the printString to the window to insert, inspect it to the inspect action (DevTools opens an inspector)."
Class {
	#name : #WorkspaceModel,
	#superclass : #ToolModel,
	#instVars : [
		'receiver',
		'process',
		'frame',
		'lastResult',
		'inspectAction'
	]
}

{ #category : #accessing }
WorkspaceModel >> frame: anIndex [
	frame := anIndex
]

{ #category : #accessing }
WorkspaceModel >> inspectAction: aBlock [
	"aBlock gets a description (value, class, handle) and the client."
	inspectAction := aBlock
]

{ #category : #accessing }
WorkspaceModel >> lastResult [
	^ lastResult
]

{ #category : #accessing }
WorkspaceModel >> process: aProcessId frame: anIndex [
	"Evaluate in a frame of a stopped Process from now on."
	process := aProcessId.
	frame := anIndex
]

{ #category : #accessing }
WorkspaceModel >> receiver: aHandle [
	"self is the object under aHandle from now on."
	receiver := aHandle
]

{ #category : #evaluating }
WorkspaceModel >> doIt: aString [
	self evaluate: aString then: [:r | self status: (r at: 'class') , ': ' , (r at: 'value')]
]

{ #category : #evaluating }
WorkspaceModel >> evaluate: aString then: aBlock [
	| done |
	aString isEmptyOrNil ifTrue: [^ self status: 'nothing to evaluate'].
	done := [:r | lastResult := r. aBlock value: r].
	process isNil
		ifTrue: [self request: 'evaluate' args: {'source'. aString. 'receiver'. receiver} then: done]
		ifFalse: [self request: 'process.evaluate' args: {'process'. process. 'frame'. frame. 'source'. aString} then: done]
]

{ #category : #evaluating }
WorkspaceModel >> inspectIt: aString [
	self evaluate: aString then: [:r |
		self status: (r at: 'class') , ': ' , (r at: 'value').
		inspectAction isNil ifFalse: [inspectAction value: r value: client]]
]

{ #category : #evaluating }
WorkspaceModel >> printIt: aString [
	self evaluate: aString then: [:r |
		self status: (r at: 'class').
		self changed: #printed]
]
