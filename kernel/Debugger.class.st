"The debugger's target side (module 9b): while the development protocol serves, an unhandled error stops its Process instead of ending it (UnhandledError>>defaultAction), and so do a step (Process>>stopForDebugger, the VM's interrupt where a step ends) and a suspend. A stopped Process is a DebugStop: it waits, its stack intact, and serves the commands clients send it (its frames, evaluate in a frame, proceed, restart a frame, retry a send, step, terminate) itself, on its own stack, where its Contexts are live. No timeout in a development image; a release image never stops (the protocol never starts there). Every stop is the event process.stopped, every resumption process.resumed."
Class {
	#name : #Debugger,
	#superclass : #Object,
	#classInstVars : [
		'enabled',
		'stops',
		'lock',
		'suspends'
	],
	#category : #'Kernel-Development'
}

{ #category : #stopping }
Debugger class >> park: aDebugStop [
	"The active Process stops: registered, its pending request answered with the stop, the event emitted; then it serves commands until one lets it go on, whose value it answers."
	| entry |
	lock critical: [stops at: aDebugStop process put: aDebugStop].
	entry := DevProtocol takeReplyOf: aDebugStop process.
	entry isNil ifFalse: [DevProtocol reply: entry first error: 'stopped: ' , aDebugStop errorText , ' (process ' , aDebugStop process id printString , ')'].
	DevProtocol emit: 'process.stopped' with: aDebugStop summary.
	Transcript show: 'Process ' , aDebugStop process id printString , ' stopped (' , aDebugStop reason , '): ' , aDebugStop errorText; cr.
	^ aDebugStop serve
]

{ #category : #stopping }
Debugger class >> stepStopped [
	"Process>>stopForDebugger: the active Process stopped where a step ended (or where a suspend found it); the frame below the VM's interrupt is the first."
	| p reason |
	p := ProcessorScheduler activeProcess.
	reason := (lock critical: [suspends remove: p ifAbsent: [nil]]) isNil ifTrue: ['step'] ifFalse: ['suspended'].
	^ self park: (DebugStop process: p exception: nil reason: reason frames: (self framesFrom: thisContext sender sender))
]

{ #category : #stopping }
Debugger class >> stop: anException [
	"UnhandledError>>defaultAction: the active Process stops at the error; its frames start at the one that signalled."
	^ self park: (DebugStop process: ProcessorScheduler activeProcess exception: anException reason: 'error'
		frames: (self framesFrom: anException signalerContext))
]

{ #category : #stopping }
Debugger class >> suspend: aProcess [
	"Ask aProcess to stop for the debugger where it stands (the VM's interrupt 2)."
	aProcess == ProcessorScheduler activeProcess ifTrue: [^ self error: 'a Process cannot suspend itself this way'].
	lock critical: [suspends add: aProcess].
	(aProcess primInterrupt: 2) ifFalse: [
		lock critical: [suspends remove: aProcess ifAbsent: [nil]].
		^ self error: 'the Process ' , aProcess id printString , ' cannot be suspended (ended, or not started)'].
	^ true
]

{ #category : #stopping }
Debugger class >> unpark: aDebugStop [
	lock critical: [stops removeKey: aDebugStop process ifAbsent: [nil]].
	DevProtocol emit: 'process.resumed' with: ((JsonObject new) at: 'process' put: aDebugStop process id; yourself)
]

{ #category : #stops }
Debugger class >> framesFrom: aContext [
	"The Contexts from aContext down, at most 256."
	| out ctx |
	out := OrderedCollection new.
	ctx := aContext.
	[ctx notNil and: [out size < 256]] whileTrue: [out add: ctx. ctx := ctx sender].
	^ out asArray
]

{ #category : #stops }
Debugger class >> processWithId: anId [
	^ (ProcessorScheduler primAllProcesses detect: [:p | p notNil and: [p id = anId]] ifNone: [nil])
]

{ #category : #stops }
Debugger class >> stopOf: aProcess [
	lock isNil ifTrue: [^ nil].
	^ lock critical: [stops at: aProcess ifAbsent: [nil]]
]

{ #category : #stops }
Debugger class >> stopWithId: anId [
	lock isNil ifTrue: [^ nil].
	^ lock critical: [stops detect: [:s | s process id = anId] ifNone: [nil]]
]

{ #category : #stops }
Debugger class >> stops [
	lock isNil ifTrue: [^ #()].
	^ lock critical: [stops values asArray]
]

{ #category : #switching }
Debugger class >> disable [
	enabled := false
]

{ #category : #switching }
Debugger class >> enable [
	"From now on unhandled errors stop their Process (DevProtocol start). Never in a release image."
	Smalltalk isReleaseImage ifTrue: [^ false].
	lock isNil ifTrue: [lock := Mutex new. stops := IdentityDictionary new. suspends := IdentitySet new].
	enabled := true.
	^ true
]

{ #category : #switching }
Debugger class >> isEnabled [
	^ enabled == true
]
