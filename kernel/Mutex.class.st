"Mutual exclusion that the owning Process may enter again."
Class {
	#name : #Mutex,
	#superclass : #Object,
	#instVars : [
		'semaphore',
		'owner'
	],
	#category : #'Kernel-Processes'
}

{ #category : #accessing }
Mutex >> critical: aBlock [
	| me |
	me := ProcessorScheduler activeProcess.
	owner == me ifTrue: [^ aBlock value].
	semaphore wait.
	owner := me.
	^ aBlock ensure: [owner := nil. semaphore signal]
]

{ #category : #accessing }
Mutex >> isOwned [
	^ owner notNil
]

{ #category : #accessing }
Mutex >> setSemaphore [
	semaphore := Semaphore forMutualExclusion
]

{ #category : #accessing }
Mutex class >> new [
	^ self basicNew setSemaphore
]
