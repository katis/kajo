"The kernel's event loop (module 9a, ADR 0004): one main-affine Process at the highest priority waits on a Semaphore the shell's event queue signals once per event, takes the event (primitive 154) and dispatches it to the wrapper of its target handle, synchronously on the main thread in the turn the shell runs after posting. A native callback only enqueues and returns. Frame events go to the frame actions (the display-link probe), synthetic ones to the synthetic action (the latency measurement), the kinds that name no view (module 9c: a protocol connection's line and lost, a timer) to the action registered for the kind, and timer events to the block after:do: registered. An error in a handler is written on the Transcript and the loop goes on; where an unhandled error would stop its Process for the debugger (Debugger canStop: the host said a debugger can come, module 9b and the development answers, and the stops are under their cap) the loop instead hands itself over to a new Process and lets the erring one stop for the debugger (module 9c), so an error in a tool or an app's handler never stops the loop, with or without a client. With no shell, start answers false and nothing runs."
Class {
	#name : #UIEventLoop,
	#superclass : #Object,
	#classInstVars : [
		'semaphore',
		'process',
		'frameActions',
		'syntheticAction',
		'handled',
		'errors',
		'kindActions',
		'timers',
		'nextTimer',
		'generation',
		'handOvers'
	]
}

{ #category : #accessing }
UIEventLoop class >> errorCount [
	^ errors
]

{ #category : #accessing }
UIEventLoop class >> handledCount [
	^ handled
]

{ #category : #accessing }
UIEventLoop class >> process [
	^ process
]

{ #category : #actions }
UIEventLoop class >> after: milliseconds do: aBlock [
	"aBlock runs in the event loop once milliseconds have passed: the host posts a timer event (primitive 164). Answers the timer's token, or nil with no host to post it (headless)."
	| token |
	timers isNil ifTrue: [timers := Dictionary new. nextTimer := 0].
	nextTimer := nextTimer + 1.
	token := nextTimer.
	timers at: token put: aBlock.
	(ClientTransport timer: milliseconds token: token) isNil ifTrue: [timers removeKey: token. ^ nil].
	^ token
]

{ #category : #actions }
UIEventLoop class >> cancelTimer: aToken [
	timers isNil ifFalse: [timers removeKey: aToken ifAbsent: [nil]]
]

{ #category : #actions }
UIEventLoop class >> on: aKind do: aBlock [
	"aBlock runs with each event of aKind (a Symbol of UIEvent kinds) instead of the target's wrapper: module 9c's #line and #lost of the protocol client's connections."
	kindActions isNil ifTrue: [kindActions := IdentityDictionary new].
	kindActions at: aKind put: aBlock
]

{ #category : #actions }
UIEventLoop class >> onFrame: aBlock [
	"aBlock runs with each frame event (the shell posts one per display-link callback when asked)."
	frameActions add: aBlock
]

{ #category : #actions }
UIEventLoop class >> onSynthetic: aBlock [
	syntheticAction := aBlock
]

{ #category : #actions }
UIEventLoop class >> removeFrameActions [
	frameActions := OrderedCollection new
]

{ #category : #primitives }
UIEventLoop class >> eventSemaphore: aSemaphore [
	"Primitive 153: aSemaphore is signalled once per event the shell posts (events already queued are signalled now)."
	<primitive: 153>
	^ self error: 'no shell to take events from'
]

{ #category : #primitives }
UIEventLoop class >> nextEvent [
	"Primitive 154: the oldest queued event as {kind. target. value. microseconds}, or nil."
	<primitive: 154>
	^ nil
]

{ #category : #running }
UIEventLoop class >> deliver: anEvent [
	| k |
	k := anEvent kind.
	k == #frame ifTrue: [^ frameActions do: [:b | b cull: anEvent]].
	k == #synthetic ifTrue: [^ syntheticAction ifNotNil: [:b | b cull: anEvent]].
	k == #timer ifTrue: [
		^ (timers isNil ifTrue: [nil] ifFalse: [timers removeKey: anEvent target ifAbsent: [nil]]) ifNotNil: [:b | b value]].
	(kindActions notNil and: [kindActions includesKey: k]) ifTrue: [^ (kindActions at: k) cull: anEvent].
	^ (View at: anEvent target) ifNotNil: [:v | v handleEvent: anEvent]
]

{ #category : #running }
UIEventLoop class >> dispatch: anEvent [
	"Handle one event: frame and synthetic events by their actions, timers by their blocks, the kinds registered with on:do: by theirs, the rest by the wrapper of the target handle. An error goes to the Transcript; where it would stop for the debugger (Debugger canStop) it stops the loop's Process after a new loop Process has taken over (module 9c)."
	handled := handled + 1.
	[self deliver: anEvent]
		on: Error
		do: [:e |
			errors := errors + 1.
			(process == ProcessorScheduler activeProcess and: [Debugger canStop])
				ifTrue: [
					self handOver.
					e pass]
				ifFalse: [Transcript show: 'event ' , anEvent printString , ': ' , e messageText; cr]]
]

{ #category : #running }
UIEventLoop class >> handOver [
	"A new loop Process takes the events from now on; the active one, the old loop, ends after the event it is handling (once the debugger lets it go on)."
	handOvers := (handOvers ifNil: [0]) + 1.
	self startGeneration
]

{ #category : #running }
UIEventLoop class >> handOverCount [
	^ handOvers ifNil: [0]
]

{ #category : #running }
UIEventLoop class >> initialize [
	frameActions := OrderedCollection new.
	handled := 0.
	errors := 0
]

{ #category : #running }
UIEventLoop class >> isRunning [
	^ process notNil and: [process isTerminated not]
]

{ #category : #running }
UIEventLoop class >> resumeAfterSnapshot [
	"A saved image resumed in a new shell: the loop's Process was saved waiting on its Semaphore; register the Semaphore with the new shell's queue."
	(self isRunning and: [View hasShell]) ifTrue: [self eventSemaphore: semaphore]
]

{ #category : #running }
UIEventLoop class >> run [
	"The loop of an image saved before module 9c's generations."
	^ self runGeneration: generation
]

{ #category : #running }
UIEventLoop class >> runGeneration: aNumber [
	"Take events while this Process is the loop: a hand-over makes a new generation, and the old Process ends after its event."
	[aNumber = generation] whileTrue: [
		semaphore wait.
		aNumber = generation
			ifTrue: [self nextEvent ifNotNil: [:a | self dispatch: (UIEvent fromArray: a)]]
			ifFalse: [semaphore signal]]
]

{ #category : #running }
UIEventLoop class >> start [
	"Start the loop on the main thread; answers false with no shell."
	self isRunning ifTrue: [^ true].
	View hasShell ifFalse: [^ false].
	semaphore := Semaphore new.
	self eventSemaphore: semaphore.
	self startGeneration.
	^ true
]

{ #category : #running }
UIEventLoop class >> startGeneration [
	generation := (generation ifNil: [0]) + 1.
	process := self fork: #runGeneration: with: generation priority: 2 main: true exit: nil
]

{ #category : #running }
UIEventLoop class >> stop [
	process ifNotNil: [:p | p terminate].
	process := nil
]
