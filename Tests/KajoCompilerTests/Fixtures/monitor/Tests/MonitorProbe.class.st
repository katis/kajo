"The third review's small fixes, item 2: a Monitor whose mutex the test holds, Processes queued to enter it, waiting on its condition, and consumers of a SharedQueue, each terminated at a chosen point."
Class {
	#name : #MonitorProbe,
	#superclass : #Object,
	#classVars : [
		'Mon',
		'Queue',
		'Entered'
	]
}

{ #category : #probing }
MonitorProbe class >> consume [
	^ Queue next
]

{ #category : #probing }
MonitorProbe class >> enter [
	Mon critical: [Entered := Entered + 1].
	^ 1
]

{ #category : #probing }
MonitorProbe class >> entered [
	^ Entered
]

{ #category : #probing }
MonitorProbe class >> excess [
	^ (Mon instVarAt: 1) excessSignals
]

{ #category : #probing }
MonitorProbe class >> produce [
	Queue nextPut: 5.
	^ 0
]

{ #category : #probing }
MonitorProbe class >> queueExcess [
	^ ((Queue instVarAt: 1) instVarAt: 1) excessSignals
]

{ #category : #probing }
MonitorProbe class >> queueWaiters [
	^ ((Queue instVarAt: 1) instVarAt: 2) size
]

{ #category : #probing }
MonitorProbe class >> release [
	(Mon instVarAt: 1) signal.
	^ 0
]

{ #category : #probing }
MonitorProbe class >> setUp [
	"The Monitor held by the test: its mutex's one signal taken."
	Mon := Monitor new.
	(Mon instVarAt: 1) wait.
	Queue := SharedQueue new.
	Entered := 0.
	^ 0
]

{ #category : #probing }
MonitorProbe class >> setUpFree [
	Mon := Monitor new.
	Queue := SharedQueue new.
	Entered := 0.
	^ 0
]

{ #category : #probing }
MonitorProbe class >> waitInside [
	Mon critical: [Entered := Entered + 1. Mon wait].
	^ 1
]

{ #category : #probing }
MonitorProbe class >> waiters [
	^ (Mon instVarAt: 2) size
]
