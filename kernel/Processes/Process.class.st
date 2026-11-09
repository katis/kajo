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
	]
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
	"Ends the Process after running its pending ensure: and ifCurtailed: blocks in it, innermost first (module 9b). The active Process unwinds at once. Another one is interrupted (ready, waiting or running elsewhere) to unwind itself when it next runs, and the sender waits for it to end, at most about Process unwindBudgetMs; past that it is ended where it stands. Answers whether the unwinding ran to its end (the development answers): false when it was cut off, which is counted (Unwinding cutOffCount) and written on the Transcript with the block it stood in."
	^ self terminateReporting == true
]

{ #category : #debugging }
Process >> primStep: aMode frame: aContext [
	"The active Process steps relative to aContext, a live frame of its own (module 9b): aMode 1 into, 2 over, 3 out, 0 off. It stops (stopForDebugger) at the poll the mode's rule picks or when aContext returns."
	<primitive: 158>
	^ self primitiveFailed
]

{ #category : #debugging }
Process >> stopForDebugger [
	"Sent by the VM to the Process itself where a step or a suspend stopped it at a send (module 9b): the debugger takes over until a client acts."
	^ Debugger stepStoppedAtSend: true
]

{ #category : #debugging }
Process >> stopForDebuggerAfterSend [
	"As stopForDebugger, where the Process is after a send (a step out of a frame, a suspend of a waiting Process)."
	^ Debugger stepStoppedAtSend: false
]

{ #category : #terminating }
Process >> awaitUnwinding [
	"The receiver is unwinding itself (terminateUnwinding) to its end: wait for that at most about Process unwindBudgetMs of 1 ms Delays, then end it where it stands. Answers true when it ended by itself, else the cut-off's description; a cut-off is counted and reported (Unwinding cutOff:after:)."
	| waited |
	waited := 0.
	[self isTerminated or: [waited >= Process unwindBudgetMs]] whileFalse: [
		(Delay forMilliseconds: 1) wait.
		waited := waited + 1].
	self isTerminated ifTrue: [Unwinding forget: self. ^ true].
	self primTerminate.
	^ Unwinding cutOff: self after: waited
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
Process >> terminateReporting [
	"terminate, answering true when the unwinding ran to its end and otherwise the cut-off's description (the Transcript's line without the count): what the development protocol's process.terminate answers."
	self == ProcessorScheduler activeProcess ifTrue: [^ self terminateUnwinding].
	self isTerminated ifTrue: [^ true].
	(self primInterrupt: 1) ifFalse: [self primTerminate. ^ true].
	^ self awaitUnwinding
]

{ #category : #terminating }
Process >> terminateUnwinding [
	"Run by the Process itself (the active one, or an interrupted one: primitive 155): every pending ensure: and ifCurtailed: block from here down, innermost first, then the end. An error in an unwind block is reported and the unwinding goes on. Each block is noted (Unwinding note:for:) so a Process waiting for this one can say where it stood if the bound cuts it off."
	| ctx unwindBlock |
	ctx := thisContext findNextUnwindContextUpTo: nil.
	[ctx isNil] whileFalse: [
		(ctx tempAt: 2) isNil ifTrue: [
			ctx tempAt: 2 put: true.
			unwindBlock := ctx tempAt: 1.
			thisContext terminateTo: ctx.
			Unwinding note: unwindBlock for: self.
			[unwindBlock value] on: Error do: [:e | Transcript showLine: 'Error in an unwind block while terminating: ' , e printString]].
		ctx := ctx findNextUnwindContextUpTo: nil].
	Unwinding forget: self.
	self primTerminate
]

{ #category : #terminating }
Process class >> unwindBudgetMs [
	"How long, about, terminate waits for another Process to run its unwind blocks before it ends it anyway."
	^ 1000
]
