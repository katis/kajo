"The debugger's target side (module 9b; the development answers, docs/modules/development-answers.md): in a development image whose host said a debugger can still come (Debugger hostStopsErrors: a development app, the shells' developer modes, kajo run --protocol), an unhandled error stops its Process instead of ending it (UnhandledError>>defaultAction), with or without a client, and so do a step (Process>>stopForDebugger, the VM's interrupt where a step ends) and a suspend. A stopped Process is a DebugStop: it waits, its stack intact, and serves the commands clients send it (its frames, evaluate in a frame, proceed, restart a frame, retry a send, step, terminate) itself, on its own stack, where its Contexts are live; a client that connects later finds it (process.list, and session.open's answer lists every standing stop). No timeout in a development image; but at most stopCap error stops stand at once: past it the newest error is reported and its Process ended as in a batch host, counted (refusedStops) and written on the Transcript. A release image and a batch host (kajo test, kajo run, the image build, the shells' tests, golden and scenario modes) never stop. Every stop is the event process.stopped, every resumption process.resumed."
Class {
	#name : #Debugger,
	#superclass : #Object,
	#classInstVars : [
		'stops',
		'lock',
		'suspends',
		'refused'
	]
}

{ #category : #stopping }
Debugger class >> park: aDebugStop [
	"The active Process stops: registered, its pending request answered with the stop, the event emitted; then it serves commands until one lets it go on, whose value it answers."
	self ensureTables.
	lock critical: [stops at: aDebugStop process put: aDebugStop].
	^ self parked: aDebugStop
]

{ #category : #stopping }
Debugger class >> parked: aDebugStop [
	"aDebugStop is registered: what a client that is connected learns of it now, then the commands until one lets the Process go on."
	| entry |
	aDebugStop noteSummary.
	entry := DevProtocol takeReplyOf: aDebugStop process.
	entry isNil ifFalse: [DevProtocol reply: entry first error: 'stopped: ' , aDebugStop errorText , ' (process ' , aDebugStop process id printString , ')'].
	DevProtocol emit: 'process.stopped' with: aDebugStop summary.
	Transcript showLine: 'Process ' , aDebugStop process id printString , ' stopped (' , aDebugStop reason , '): ' , aDebugStop errorText.
	^ aDebugStop serve
]

{ #category : #stopping }
Debugger class >> refusedStops [
	"Errors reported and ended because stopCap stops stood (telemetry a host reads)."
	^ refused ifNil: [0]
]

{ #category : #stopping }
Debugger class >> stepStoppedAtSend: aBoolean [
	"Process>>stopForDebugger: the active Process stopped where a step ended (or where a suspend found it), at a send it is about to make or after one; the frame below the VM's interrupt is the first."
	| p reason |
	self ensureTables.
	p := ProcessorScheduler activeProcess.
	reason := (lock critical: [suspends remove: p ifAbsent: [nil]]) isNil ifTrue: ['step'] ifFalse: ['suspended'].
	^ self park: ((DebugStop process: p exception: nil reason: reason frames: (self framesFrom: thisContext sender sender))
		atSend: aBoolean; yourself)
]

{ #category : #stopping }
Debugger class >> stop: anException [
	"The active Process stops at the error; its frames start at the one that signalled."
	^ self stop: anException ifFull: [self error: 'no stop: ' , self stopCap printString , ' stops stand']
]

{ #category : #stopping }
Debugger class >> stop: anException ifFull: aBlock [
	"UnhandledError>>defaultAction: the active Process stops at the error, unless stopCap error stops stand already: then the refusal is counted and written on the Transcript and aBlock answers (the batch host's report-and-end)."
	| s full |
	self ensureTables.
	s := DebugStop process: ProcessorScheduler activeProcess exception: anException reason: 'error'
		frames: (self framesFrom: anException signalerContext).
	full := lock critical: [
		(stops count: [:x | x reason = 'error']) >= self stopCap
			ifTrue: [refused := (refused ifNil: [0]) + 1. true]
			ifFalse: [stops at: s process put: s. false]].
	full ifTrue: [
		Transcript showLine: 'Process ' , s process id printString , ' not stopped: ' , self stopCap printString
			, ' stops stand (Debugger stopCap); reported and ended (' , refused printString , ' refused so far)'.
		^ aBlock value].
	^ self parked: s
]

{ #category : #stopping }
Debugger class >> stopCap [
	"How many error stops may stand at once. Each holds its Process: the stack (a malloc'ed segment, 512 KiB reserved, the pages it touched resident), the frames' Contexts and the exception. A loop that fails on every frame would otherwise keep one per frame for as long as no client comes; past the cap an error is reported and its Process ended."
	^ 32
]

{ #category : #stopping }
Debugger class >> suspend: aProcess [
	"Ask aProcess to stop for the debugger where it stands (the VM's interrupt 2)."
	aProcess == ProcessorScheduler activeProcess ifTrue: [^ self error: 'a Process cannot suspend itself this way'].
	self ensureTables.
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
Debugger class >> isStoppedProcessId: anId [
	"Whether the Process with id anId stands stopped for the debugger (a host waiting for a Process it spawned asks: KajoAppRunner)."
	^ (self stopWithId: anId) notNil
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
Debugger class >> canStop [
	"Whether an unhandled error of the active Process would stop it now: the host says a debugger can come and fewer than stopCap error stops stand (UIEventLoop hands itself over only then)."
	self stopsErrors ifFalse: [^ false].
	self ensureTables.
	^ lock critical: [(stops count: [:x | x reason = 'error']) < self stopCap]
]

{ #category : #switching }
Debugger class >> ensureTables [
	"The tables exist from the image build on (initialize); an image made without it gets them here."
	lock isNil ifTrue: [self initialize]
]

{ #category : #switching }
Debugger class >> hostStopsErrors [
	"The host's setting (primitive 165, ShellVM.stopsForDebugger): whether a debugger can still come to this image, so an unhandled error stops its Process. False in a release image and in a host with no shell (kajo run, kajo test, the image build)."
	^ self primHostStopsErrors == true
]

{ #category : #switching }
Debugger class >> initialize [
	lock := Mutex new.
	stops := IdentityDictionary new.
	suspends := IdentitySet new.
	refused := 0
]

{ #category : #switching }
Debugger class >> primHostStopsErrors [
	<primitive: 165>
	^ false
]

{ #category : #switching }
Debugger class >> stopsErrors [
	"The one rule UnhandledError>>defaultAction reads: an unhandled error stops its Process in a development image whose host said a debugger can still come. Never in a release image."
	Smalltalk isReleaseImage ifTrue: [^ false].
	^ self hostStopsErrors
]
