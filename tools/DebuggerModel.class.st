"A debugger's model (module 9c): a stopped Process of a target (process.stopped: the reason, the error, the frames), the selected frame's method, source with the range the pc is at, receiver and variables, and a workspace evaluating in that frame. Proceed, restart the frame, retry the send, step into, over or out, terminate. Saving the frame's method is fix and continue: compile it, then restart the frame, which runs the send again and finds the new method. At a doesNotUnderstand: stop, define the method opens a browser on the receiver's class with a template, and saving it retries the send (9b's define-and-proceed). When the Process stops again (a step) the frames are fetched again; when it is resumed or ends, the model says so."
Class {
	#name : #DebuggerModel,
	#superclass : #ToolModel,
	#instVars : [
		'process',
		'reason',
		'error',
		'frames',
		'frameIndex',
		'state',
		'workspace',
		'browseAction'
	],
	#category : #'Tools-Models'
}

{ #category : #accessing }
DebuggerModel >> browseAction: aBlock [
	"aBlock gets a class name, a selector and a block to run once the method compiles (define-and-retry)."
	browseAction := aBlock
]

{ #category : #accessing }
DebuggerModel >> error [
	^ error
]

{ #category : #accessing }
DebuggerModel >> frame [
	(frames isNil or: [frameIndex isNil or: [frameIndex > frames size]]) ifTrue: [^ nil].
	^ frames at: frameIndex
]

{ #category : #accessing }
DebuggerModel >> frameIndex [
	^ frameIndex
]

{ #category : #accessing }
DebuggerModel >> frameTitles [
	^ (self frames collect: [:f | f at: 'method']) asArray
]

{ #category : #accessing }
DebuggerModel >> frames [
	^ frames ifNil: [#()]
]

{ #category : #accessing }
DebuggerModel >> process [
	^ process
]

{ #category : #accessing }
DebuggerModel >> range [
	"{start. stop} in the frame's source: the send the frame is at."
	^ self frame ifNotNil: [:f | f at: 'range']
]

{ #category : #accessing }
DebuggerModel >> reason [
	^ reason
]

{ #category : #accessing }
DebuggerModel >> source [
	^ self frame ifNil: [''] ifNotNil: [:f | (f at: 'source') ifNil: ['']]
]

{ #category : #accessing }
DebuggerModel >> state [
	"#stopped, #running or #ended."
	^ state
]

{ #category : #accessing }
DebuggerModel >> title [
	^ 'Debugger: process ' , process printString , ' (' , reason displayString , ') ' , error displayString
]

{ #category : #accessing }
DebuggerModel >> variables [
	"{name. value} of the frame's receiver and variables."
	| f out |
	f := self frame.
	f isNil ifTrue: [^ #()].
	out := OrderedCollection new.
	out add: {'self'. (f at: 'receiver') at: 'value'}.
	(f at: 'variables') do: [:v | out add: {v at: 'name'. v at: 'value'}].
	^ out asArray
]

{ #category : #accessing }
DebuggerModel >> workspace [
	^ workspace
]

{ #category : #commands }
DebuggerModel >> after: aString [
	"A command the Process acted on: it runs (process.resumed, or stopped again)."
	state := #running.
	self status: aString.
	self changed: #state
]

{ #category : #commands }
DebuggerModel >> defineMissingMethod [
	"At a doesNotUnderstand: stop: the receiver's class in a browser with a template for the selector; saving it retries the send."
	| i sel cls |
	self isDoesNotUnderstand ifFalse: [^ self status: 'not stopped at doesNotUnderstand:'].
	i := error indexOfSubstring: ' #'.
	sel := error copyFrom: i + 2 to: error byteSize.
	cls := ((frames at: 1) at: 'receiver') at: 'class'.
	browseAction isNil ifTrue: [^ self status: 'no browser to define ' , cls , '>>' , sel].
	browseAction value: cls value: sel value: [:selector | self retrySend]
]

{ #category : #commands }
DebuggerModel >> isDoesNotUnderstand [
	^ error notNil and: [error beginsWith: 'MessageNotUnderstood']
]

{ #category : #commands }
DebuggerModel >> proceed [
	self request: 'process.proceed' args: {'process'. process} then: [:r | self after: 'proceeded']
]

{ #category : #commands }
DebuggerModel >> restart [
	self request: 'process.restart' args: {'process'. process. 'frame'. frameIndex} then: [:r |
		self after: 'restarted frame ' , frameIndex printString , (self unwindingOf: r)]
]

{ #category : #commands }
DebuggerModel >> retrySend [
	self request: 'process.retrySend' args: {'process'. process} then: [:r | self after: 'retried the send' , (self unwindingOf: r)]
]

{ #category : #commands }
DebuggerModel >> save: aString [
	"Fix and continue: compile the selected frame's method from aString, then restart the frame."
	| m |
	m := self methodClassAndSide.
	m isNil ifTrue: [^ self status: 'a block''s frame: save its method in a browser'].
	self request: 'method.compile' args: {'className'. m first. 'source'. aString. 'side'. m at: 2} then: [:r |
		self status: 'compiled ' , m first , '>>' , (r at: 'selector') , ', restarting'.
		self restart]
]

{ #category : #commands }
DebuggerModel >> step: aMode [
	"into, over or out from the selected frame; process.stopped follows where the step ends."
	self request: 'process.step' args: {'process'. process. 'mode'. aMode. 'frame'. frameIndex} then: [:r | self after: 'stepping ' , aMode]
]

{ #category : #commands }
DebuggerModel >> terminate [
	self request: 'process.terminate' args: {'process'. process} then: [:r |
		state := #ended.
		self status: 'terminated' , (self unwindingOf: r).
		self changed: #state]
]

{ #category : #commands }
DebuggerModel >> unwindingOf: aResult [
	"The development answers: an unwinding that did not run to its end within the bound is said, never silent."
	((aResult isKindOf: JsonObject) and: [(aResult at: 'unwound') == false]) ifFalse: [^ ''].
	^ '; ' , ((aResult at: 'cutOff') ifNil: ['its unwinding did not run to its end'])
]

{ #category : #events }
DebuggerModel >> resumed [
	state := #running.
	self status: 'running'.
	self changed: #state
]

{ #category : #events }
DebuggerModel >> stopped: anEvent [
	"process.stopped for this Process: why, the error, and its frames fetched."
	process := anEvent at: 'process'.
	reason := anEvent at: 'reason'.
	error := anEvent at: 'error'.
	state := #stopped.
	workspace isNil ifTrue: [workspace := WorkspaceModel new client: client; yourself].
	self status: reason , ': ' , error displayString.
	self changed: #state.
	self refresh
]

{ #category : #frames }
DebuggerModel >> methodClassAndSide [
	"{class name. side. selector} of the selected frame's method ('Foo>>bar', 'Foo class>>bar'), or nil for a block's frame."
	| m i cls sel |
	m := self frame ifNil: [^ nil] ifNotNil: [:f | f at: 'method'].
	i := m indexOfSubstring: '>>'.
	i = 0 ifTrue: [^ nil].
	cls := m copyFrom: 1 to: i - 1.
	sel := m copyFrom: i + 2 to: m byteSize.
	sel = '[]' ifTrue: [^ nil].
	(cls endsWith: ' class') ifTrue: [^ {cls copyFrom: 1 to: cls byteSize - 6. 'class'. sel}].
	^ {cls. 'instance'. sel}
]

{ #category : #frames }
DebuggerModel >> refresh [
	self request: 'process.frames' args: {'process'. process} then: [:r |
		frames := r.
		state := #stopped.
		self selectFrame: 1.
		self changed: #frames]
]

{ #category : #frames }
DebuggerModel >> selectFrame: anIndex [
	frameIndex := anIndex.
	workspace process: process frame: anIndex.
	self changed: #frame
]
