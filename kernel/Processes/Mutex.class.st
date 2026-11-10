"Mutual exclusion that the owning Process may enter again."
Class {
	#name : #Mutex,
	#superclass : #Object,
	#instVars : [
		'semaphore',
		'owner'
	]
}

{ #category : #accessing }
Mutex >> critical: aBlock [
	"As Semaphore>>critical: (the review fixes, item 14): the wait inside the protected block, caught set right after it."
	| me caught |
	me := ProcessorScheduler activeProcess.
	owner == me ifTrue: [^ aBlock value].
	caught := false.
	^ [semaphore wait. caught := true. owner := me. aBlock value] ensure: [caught ifTrue: [owner := nil. semaphore signal]]
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
