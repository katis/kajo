"The VM's semaphore: wait suspends the Process until a signal; waiters are woken in order."
Class {
	#name : #Semaphore,
	#superclass : #Object,
	#instVars : [
		'excessSignals',
		'firstWaiter',
		'lastWaiter'
	],
	#category : #'Kernel-Processes'
}

{ #category : #accessing }
Semaphore >> critical: aBlock [
	self wait.
	^ aBlock ensure: [self signal]
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
