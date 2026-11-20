"A Mutex with conditions: inside critical:, wait releases the monitor until another Process signals."
Class {
	#name : #Monitor,
	#superclass : #Object,
	#instVars : [
		'mutex',
		'waiting',
		'owner'
	]
}

{ #category : #accessing }
Monitor >> abandon: aSemaphore [
	"Run by a Process whose wait on aSemaphore was cut short (terminated while it waited, or after it was woken and before it held the monitor again): take the monitor back so critical: gives it back once, and take aSemaphore out of the waiters, or, when a signal already took it out, pass that wakeup on to the next waiter (the third review's small fixes, item 2)."
	mutex wait.
	owner := ProcessorScheduler activeProcess.
	(waiting identityIncludes: aSemaphore)
		ifTrue: [waiting remove: aSemaphore]
		ifFalse: [self signal]
]

{ #category : #accessing }
Monitor >> critical: aBlock [
	"As Mutex>>critical: (the review fixes, item 14), with the owner as the flag: the wait inside the protected block and owner set right after it (no send between), so a Process terminated before it holds the monitor, or while wait has given it back, gives nothing back (the third review's small fixes, item 2)."
	| me |
	me := ProcessorScheduler activeProcess.
	^ [mutex wait. owner := me. aBlock value] ensure: [owner == me ifTrue: [owner := nil. mutex signal]]
]

{ #category : #accessing }
Monitor >> setUp [
	mutex := Semaphore forMutualExclusion.
	waiting := OrderedCollection new
]

{ #category : #accessing }
Monitor >> signal [
	"Inside critical: wake one waiter."
	waiting isEmpty ifFalse: [waiting removeFirst signal]
]

{ #category : #accessing }
Monitor >> signalAll [
	[waiting isEmpty] whileFalse: [waiting removeFirst signal]
]

{ #category : #accessing }
Monitor >> wait [
	"Inside critical: release the monitor, sleep until signalled, take it again. Cut short (the Process terminated while it waits or before it holds the monitor again), abandon: takes the monitor back for critical: to give back and leaves no dead waiter behind. Everything from queueing the condition Semaphore on is inside the ifCurtailed: (the failed sanitizer gate's part: a termination at the poll of the mutex's signal left the monitor held for ever, one at the poll of the ifCurtailed: send a dead waiter), and released, stored with no poll after the mutex's signal, says which side of that signal a termination fell on: before it this Process still holds the monitor (critical: gives it back) and only its Semaphore leaves the waiters."
	| s me released |
	me := ProcessorScheduler activeProcess.
	s := Semaphore new.
	released := false.
	[waiting addLast: s.
	owner := nil.
	mutex signal.
	released := true.
	s wait.
	mutex wait.
	owner := me]
		ifCurtailed: [
			released
				ifTrue: [owner == me ifFalse: [self abandon: s]]
				ifFalse: [
					owner := me.
					(waiting identityIncludes: s) ifTrue: [waiting remove: s]]]
]

{ #category : #accessing }
Monitor class >> new [
	^ self basicNew setUp
]
