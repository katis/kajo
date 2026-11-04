"The kernel's event loop (module 9a, ADR 0004): one main-affine Process at the highest priority waits on a Semaphore the shell's event queue signals once per event, takes the event (primitive 154) and dispatches it to the wrapper of its target handle, synchronously on the main thread in the turn the shell runs after posting. A native callback only enqueues and returns. Frame events go to the frame actions (the display-link probe), synthetic ones to the synthetic action (the latency measurement). An error in a handler is written on the Transcript and the loop goes on. With no shell, start answers false and nothing runs."
Class {
	#name : #UIEventLoop,
	#superclass : #Object,
	#classInstVars : [
		'semaphore',
		'process',
		'frameActions',
		'syntheticAction',
		'handled',
		'errors'
	],
	#category : #'Kernel-UI'
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
UIEventLoop class >> dispatch: anEvent [
	"Handle one event: frame and synthetic events by their actions, the rest by the wrapper of the target handle."
	handled := handled + 1.
	[anEvent kind == #frame
		ifTrue: [frameActions do: [:b | b cull: anEvent]]
		ifFalse: [
			anEvent kind == #synthetic
				ifTrue: [syntheticAction ifNotNil: [:b | b cull: anEvent]]
				ifFalse: [(View at: anEvent target) ifNotNil: [:v | v handleEvent: anEvent]]]]
		on: Error
		do: [:e |
			errors := errors + 1.
			Transcript show: 'event ' , anEvent printString , ': ' , e messageText; cr]
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
	[semaphore wait.
	 self nextEvent ifNotNil: [:a | self dispatch: (UIEvent fromArray: a)]] repeat
]

{ #category : #running }
UIEventLoop class >> start [
	"Start the loop on the main thread; answers false with no shell."
	self isRunning ifTrue: [^ true].
	View hasShell ifFalse: [^ false].
	semaphore := Semaphore new.
	self eventSemaphore: semaphore.
	process := self fork: #run with: nil priority: 2 main: true exit: nil.
	^ true
]

{ #category : #running }
UIEventLoop class >> stop [
	process ifNotNil: [:p | p terminate].
	process := nil
]
