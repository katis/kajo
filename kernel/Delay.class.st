"Suspends the Process for a time (the VM's one-shot timer signals a Semaphore). A Delay being waited on is registered with its class, so a saved image can re-arm it: the VM's timers are not saved (module 8c). The time a Delay has left is taken just before the save and starts again when the image resumes; the time the image spent on disk is not counted."
Class {
	#name : #Delay,
	#superclass : #Object,
	#instVars : [
		'milliseconds',
		'semaphore',
		'deadline',
		'remaining'
	],
	#classInstVars : [
		'pending',
		'lock',
		'rearmed'
	],
	#category : #'Kernel-Processes'
}

{ #category : #accessing }
Delay >> milliseconds [
	^ milliseconds
]

{ #category : #accessing }
Delay >> remainingMicroseconds [
	^ remaining
]

{ #category : #accessing }
Delay >> remainingMicroseconds: n [
	remaining := n
]

{ #category : #accessing }
Delay >> semaphore [
	^ semaphore
]

{ #category : #accessing }
Delay >> setMilliseconds: n [
	milliseconds := n
]

{ #category : #accessing }
Delay >> wait [
	semaphore := Semaphore new.
	deadline := Smalltalk microsecondClock + (milliseconds * 1000).
	remaining := milliseconds * 1000.
	self class register: self.
	self delay: milliseconds signal: semaphore.
	[semaphore wait] ensure: [self class unregister: self]
]

{ #category : #snapshots }
Delay >> noteRemainingAt: now [
	remaining := deadline - now max: 0
]

{ #category : #snapshots }
Delay >> pendingFor: microseconds [
	"As wait leaves a Delay before it blocks, without arming the timer (tests)."
	semaphore := Semaphore new.
	deadline := Smalltalk microsecondClock + microseconds.
	remaining := microseconds
]

{ #category : #snapshots }
Delay >> rearm [
	"Arm the VM's timer again for the time left at the save, from now."
	deadline := Smalltalk microsecondClock + remaining.
	self delay: remaining // 1000 signal: semaphore
]

{ #category : #accessing }
Delay class >> forMilliseconds: n [
	^ self basicNew setMilliseconds: n
]

{ #category : #accessing }
Delay class >> forSeconds: n [
	^ self forMilliseconds: n * 1000
]

{ #category : #accessing }
Delay class >> initialize [
	pending := IdentitySet new.
	lock := Mutex new.
	rearmed := 0
]

{ #category : #pending }
Delay class >> isPending: aDelay [
	^ lock critical: [pending includes: aDelay]
]

{ #category : #pending }
Delay class >> pendingCount [
	^ lock critical: [pending size]
]

{ #category : #pending }
Delay class >> rearmedCount [
	^ rearmed
]

{ #category : #pending }
Delay class >> register: aDelay [
	lock critical: [pending add: aDelay]
]

{ #category : #pending }
Delay class >> unregister: aDelay [
	lock critical: [pending remove: aDelay ifAbsent: [nil]]
]

{ #category : #snapshots }
Delay class >> prepareSnapshot [
	"Just before the image is saved: the time each pending Delay has left."
	| now |
	now := Smalltalk microsecondClock.
	lock critical: [pending do: [:d | d noteRemainingAt: now]]
]

{ #category : #snapshots }
Delay class >> resumeAfterSnapshot [
	"The image resumed: the VM's timers were not saved, so every pending Delay is armed again for the time it had left."
	lock critical: [
		pending do: [:d |
			d rearm.
			rearmed := rearmed + 1]]
]
