"A Mutex with conditions: inside critical:, wait releases the monitor until another Process signals."
Class {
	#name : #Monitor,
	#superclass : #Object,
	#instVars : [
		'mutex',
		'waiting'
	]
}

{ #category : #accessing }
Monitor >> critical: aBlock [
	mutex wait.
	^ aBlock ensure: [mutex signal]
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
	"Inside critical: release the monitor, sleep until signalled, take it again."
	| s |
	s := Semaphore new.
	waiting addLast: s.
	mutex signal.
	s wait.
	mutex wait
]

{ #category : #accessing }
Monitor class >> new [
	^ self basicNew setUp
]
