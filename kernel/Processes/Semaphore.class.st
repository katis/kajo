"The VM's semaphore: wait suspends the Process until a signal; waiters are woken in order."
Class {
	#name : #Semaphore,
	#superclass : #Object,
	#instVars : [
		'excessSignals',
		'firstWaiter',
		'lastWaiter'
	]
}

{ #category : #accessing }
Semaphore >> critical: aBlock [
	"The wait is inside the protected block and caught says whether this Process took the signal (the review fixes, item 14, Pharo's shape): a Process terminated before its wait, or while it waits (the VM unlinks it), signals nothing; one that took the signal sets caught before its next poll (no send between; the VM leaves a terminate asked meanwhile for that poll), so its ensure block gives the signal back."
	| caught |
	caught := false.
	^ [self wait. caught := true. aBlock value] ensure: [caught ifTrue: [self signal]]
]

{ #category : #accessing }
Semaphore >> excessSignals [
	^ self slotAt: 1
]

{ #category : #accessing }
Semaphore >> signal [
	<primitive: 23>
	^ self primitiveFailed
]

{ #category : #accessing }
Semaphore >> wait [
	<primitive: 22>
	^ self primitiveFailed
]

{ #category : #accessing }
Semaphore class >> forMutualExclusion [
	^ self new signal; yourself
]

{ #category : #accessing }
Semaphore class >> new [
	<primitive: 26>
	^ self primitiveFailed
]
