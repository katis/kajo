"The review fixes, item 14: a Semaphore and a Mutex held by the test, a Process queued in critical: on each, released and terminated before it runs again."
Class {
	#name : #CriticalProbe,
	#superclass : #Object,
	#classVars : [
		'Lock',
		'Mutex1',
		'Entered'
	]
}

{ #category : #probing }
CriticalProbe class >> enter [
	Lock critical: [Entered := Entered + 1].
	^ 1
]

{ #category : #probing }
CriticalProbe class >> enterMutex [
	Mutex1 critical: [Entered := Entered + 1].
	^ 1
]

{ #category : #probing }
CriticalProbe class >> entered [
	^ Entered
]

{ #category : #probing }
CriticalProbe class >> excess [
	^ Lock excessSignals
]

{ #category : #probing }
CriticalProbe class >> mutexExcess [
	^ (Mutex1 instVarAt: 1) excessSignals
]

{ #category : #probing }
CriticalProbe class >> release [
	Lock signal.
	^ 0
]

{ #category : #probing }
CriticalProbe class >> releaseMutex [
	(Mutex1 instVarAt: 1) signal.
	^ 0
]

{ #category : #probing }
CriticalProbe class >> setUp [
	Lock := Semaphore forMutualExclusion.
	Lock wait.
	Mutex1 := Mutex new.
	(Mutex1 instVarAt: 1) wait.
	Entered := 0.
	^ 0
]
