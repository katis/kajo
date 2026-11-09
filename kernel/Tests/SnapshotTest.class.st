"The kernel's side of saving Processes in the image (module 8c): Smalltalk snapshot: answers false in the Process that saved, the Delays a save must re-arm are registered while they are waited on, and the resume hook arms them again for the time they had left. The round trips themselves (the image resumed in a new VM) are the VM's tests."
Class {
	#name : #SnapshotTest,
	#superclass : #TestCase
}

{ #category : #accessing }
SnapshotTest >> testADelayIsPendingOnlyWhileWaitedOn [
	| d |
	d := Delay forMilliseconds: 1.
	self deny: (Delay isPending: d).
	d wait.
	self deny: (Delay isPending: d).
	Delay register: d.
	self assert: (Delay isPending: d).
	Delay unregister: d.
	self deny: (Delay isPending: d)
]

{ #category : #accessing }
SnapshotTest >> testPrepareSnapshotTakesTheTimeLeft [
	| d |
	d := (Delay forMilliseconds: 5000) pendingFor: 5000000.
	Delay register: d.
	Delay prepareSnapshot.
	Delay unregister: d.
	self assert: d remainingMicroseconds <= 5000000.
	self assert: d remainingMicroseconds > 0
]

{ #category : #accessing }
SnapshotTest >> testSnapshotAnswersFalseInTheSaver [
	"nil: the image goes to the VM's host, not to a file."
	self deny: (Smalltalk snapshot: nil)
]

{ #category : #accessing }
SnapshotTest >> testTheResumeHookRearmsPendingDelays [
	"With one Delay pending the hook arms its timer again: its Semaphore is signalled (after the millisecond it had left)."
	| d before alone |
	d := (Delay forMilliseconds: 1) pendingFor: 1000.
	Delay register: d.
	before := Delay rearmedCount.
	alone := Delay pendingCount = 1.
	alone
		ifTrue: [Delay resumeAfterSnapshot]
		ifFalse: [d rearm].
	d semaphore wait.
	Delay unregister: d.
	alone ifTrue: [self assert: Delay rearmedCount = (before + 1)]
]
