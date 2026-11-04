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
	"Ends the Process (now if it is this one, at its next check if it runs elsewhere). Its ensure: blocks do not run."
	<primitive: 24>
	^ self primitiveFailed
]
