"A Smalltalk Process: its stack is native and the VM's scheduler runs it on any worker in parallel with the others (module 3). Sealed: the slots are the scheduler's, read here with slotAt:. Made by BlockClosure>>fork and forkAt:."
Class {
	#name : #Process,
	#superclass : #Object,
	#instVars : [
		'priority',
		'state',
		'waitingOn',
		'affinity',
		'next',
		'record',
		'sp',
		'pc',
		'fp',
		'hdr',
		'result',
		'exitSemaphore',
		'id'
	],
	#category : #'Kernel-Processes'
}

{ #category : #accessing }
Process >> id [
	^ self slotAt: 13
]

{ #category : #accessing }
Process >> isMainAffine [
	^ (self slotAt: 4) = 1
]

{ #category : #accessing }
Process >> isTerminated [
	^ (self slotAt: 2) = 3
]

{ #category : #accessing }
Process >> printOn: aStream [
	aStream nextPutAll: 'a Process('; print: self id; nextPutAll: ' '; print: self state; nextPut: $)
]

{ #category : #accessing }
Process >> priority [
	^ self slotAt: 1
]

{ #category : #accessing }
Process >> state [
	^ #(#ready #running #waiting #terminated) at: (self slotAt: 2) + 1
]

{ #category : #accessing }
Process >> terminate [
	"Ends the Process after running its pending ensure: and ifCurtailed: blocks in it, innermost first (module 9b). The active Process unwinds at once. Another one is interrupted (ready, waiting or running elsewhere) to unwind itself when it next runs, and the sender waits for it to end, at most about Process unwindBudgetMs; past that it is ended where it stands."
	| waited |
	self == ProcessorScheduler activeProcess ifTrue: [^ self terminateUnwinding].
	self isTerminated ifTrue: [^ self].
	(self primInterrupt: 1) ifFalse: [^ self primTerminate].
	waited := 0.
	[self isTerminated or: [waited >= Process unwindBudgetMs]] whileFalse: [
		(Delay forMilliseconds: 1) wait.
		waited := waited + 1].
	self isTerminated ifFalse: [self primTerminate]
]

{ #category : #debugging }
Process >> primStep: aMode frame: aContext [
	"The active Process steps relative to aContext, a live frame of its own (module 9b): aMode 1 into, 2 over, 3 out, 0 off. It stops (stopForDebugger) at the poll the mode's rule picks or when aContext returns."
	<primitive: 158>
	^ self primitiveFailed
]

{ #category : #debugging }
Process >> stopForDebugger [
	"Sent by the VM to the Process itself where a step stopped it (module 9b): the debugger takes over until a client acts."
	^ Debugger stepStopped
]

{ #category : #terminating }
Process >> primInterrupt: aKind [
	"Ask the receiver, another Process that has started, to run terminateUnwinding (aKind 1) or stopForDebugger (2) when it is next resumed: false when nothing was asked (the active Process, a terminated one, one not started)."
	<primitive: 155>
	^ false
]

{ #category : #terminating }
Process >> primTerminate [
	"Ends the Process where it stands, its ensure: blocks not run (now if it is the active one, at its next check if it runs elsewhere)."
	<primitive: 24>
	^ self primitiveFailed
]

{ #category : #terminating }
Process >> terminateUnwinding [
	"Run by the Process itself (the active one, or an interrupted one: primitive 155): every pending ensure: and ifCurtailed: block from here down, innermost first, then the end. An error in an unwind block is reported and the unwinding goes on."
	| ctx unwindBlock |
	ctx := thisContext findNextUnwindContextUpTo: nil.
	[ctx isNil] whileFalse: [
		(ctx tempAt: 2) isNil ifTrue: [
			ctx tempAt: 2 put: true.
			unwindBlock := ctx tempAt: 1.
			thisContext terminateTo: ctx.
			[unwindBlock value] on: Error do: [:e | Transcript show: 'Error in an unwind block while terminating: ' , e printString; cr]].
		ctx := ctx findNextUnwindContextUpTo: nil].
	self primTerminate
]

{ #category : #terminating }
Process class >> unwindBudgetMs [
	"How long, about, terminate waits for another Process to run its unwind blocks before it ends it anyway."
	^ 1000
]
