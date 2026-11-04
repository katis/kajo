"Module 8c's round trips in Smalltalk: each scenario saves the image (Smalltalk snapshot: nil, to the host) while its Processes hold locks, wait, sit in ensure: blocks and handlers, and answers what its Processes computed. The host runs it to the end, then resumes the saved image in a fresh VM, where the saving Process continues after snapshot: and must answer the same."
Class {
	#name : #SnapshotScenarios,
	#superclass : #Object,
	#category : #'Snapshot-Tests'
}

{ #category : #scenarios }
SnapshotScenarios class >> settle [
	"Give the forked Processes time to block where the scenario wants them (not needed for the answer)."
	10 timesRepeat: [ProcessorScheduler yield].
	(Delay forMilliseconds: 20) wait
]

{ #category : #scenarios }
SnapshotScenarios class >> mutex [
	"A Mutex held by one Process, three queued on it."
	| m gate done q sum |
	m := Mutex new.
	gate := Semaphore new.
	done := Semaphore new.
	q := SharedQueue new.
	[m critical: [gate wait. q nextPut: 1]. done signal] fork.
	self settle.
	2 to: 4 do: [:i | [m critical: [q nextPut: i * 10]. done signal] fork].
	self settle.
	Smalltalk snapshot: nil.
	gate signal.
	4 timesRepeat: [done wait].
	sum := 0.
	4 timesRepeat: [sum := sum + q next].
	^ sum
]

{ #category : #scenarios }
SnapshotScenarios class >> monitor [
	"Two Processes waiting on a Monitor's condition."
	| mon ready done total |
	mon := Monitor new.
	ready := false.
	total := 0.
	done := Semaphore new.
	1 to: 2 do: [:i | [mon critical: [[ready] whileFalse: [mon wait]. total := total + i]. done signal] fork].
	self settle.
	Smalltalk snapshot: nil.
	mon critical: [ready := true. mon signal. mon signal].
	2 timesRepeat: [done wait].
	^ total
]

{ #category : #scenarios }
SnapshotScenarios class >> sharedQueue [
	"Three producers and two consumers mid-stream."
	| q done sums |
	q := SharedQueue new.
	done := Semaphore new.
	sums := Array new: 2 withAll: 0.
	1 to: 3 do: [:p | [1 to: 50 do: [:k | q nextPut: k. ProcessorScheduler yield]] fork].
	1 to: 2 do: [:c | [75 timesRepeat: [sums at: c put: (sums at: c) + q next]. done signal] fork].
	ProcessorScheduler yield.
	Smalltalk snapshot: nil.
	2 timesRepeat: [done wait].
	^ (sums at: 1) + (sums at: 2)
]

{ #category : #scenarios }
SnapshotScenarios class >> delay [
	"A Delay pending at the save fires after the resume (its timer is armed again)."
	| done |
	done := Semaphore new.
	[(Delay forMilliseconds: 1500) wait. done signal] fork.
	self settle.
	Smalltalk snapshot: nil.
	done wait.
	^ 7
]

{ #category : #scenarios }
SnapshotScenarios class >> unwinding [
	"An ensure: block pending, a non-local return through two frames, a handler whose exception is signalled after the resume, each in a Process waiting at the save."
	| go done a b c |
	go := Semaphore new.
	done := Semaphore new.
	[[go wait. a := 1] ensure: [a := a + 10]. done signal] fork.
	[b := self returnFrom: go. done signal] fork.
	[c := [go wait. (Error new) signal: 'after the resume'. 0] on: Error do: [:e | 100]. done signal] fork.
	self settle.
	Smalltalk snapshot: nil.
	3 timesRepeat: [go signal].
	3 timesRepeat: [done wait].
	^ a + b + c
]

{ #category : #scenarios }
SnapshotScenarios class >> returnFrom: aSemaphore [
	#(1) do: [:x | #(2) do: [:y | aSemaphore wait. ^ 1000]].
	^ 0
]

{ #category : #scenarios }
SnapshotScenarios class >> finalization [
	"The finalization Process, saved waiting on its Semaphore, mourns an ephemeron whose key dies after the resume."
	| key done |
	key := Array new: 3.
	done := Semaphore new.
	Ephemeron key: key value: done finalizer: [:s | s signal].
	Smalltalk snapshot: nil.
	key := nil.
	Smalltalk garbageCollect.
	done wait.
	^ 3
]

{ #category : #scenarios }
SnapshotScenarios class >> twice [
	"Saved twice: the answers are false, false where it ran (1); the first image resumes with true and saves again (10), the second with false then true (101), the image the resumed run saved with true, true (110)."
	| first second |
	first := Smalltalk snapshot: nil.
	second := Smalltalk snapshot: nil.
	^ (first ifTrue: [10] ifFalse: [1]) + (second ifTrue: [100] ifFalse: [0])
]

{ #category : #scenarios }
SnapshotScenarios class >> manyProcesses: n [
	"n Processes waiting on one Semaphore at the save (the measurement's scenario)."
	| s done |
	s := Semaphore new.
	done := Semaphore new.
	n timesRepeat: [[s wait. done signal] fork].
	self settle.
	Smalltalk snapshot: nil.
	n timesRepeat: [s signal].
	n timesRepeat: [done wait].
	^ n
]

{ #category : #scenarios }
SnapshotScenarios class >> removedMethod [
	"Module 8d: a Process waits inside a method compiled at run time, which is then replaced and removed; its frame keeps the old method, which no dictionary holds and which the saved image must still load and verify. The old method answers 1 after the wait."
	| gate done result |
	gate := Semaphore new.
	done := Semaphore new.
	SnapshotScenarios class compile: 'liveWaitOn: aSemaphore aSemaphore wait. ^ 1'.
	[result := self liveWaitOn: gate. done signal] fork.
	self settle.
	SnapshotScenarios class compile: 'liveWaitOn: aSemaphore ^ 2'.
	SnapshotScenarios class removeSelector: #liveWaitOn:.
	Smalltalk snapshot: nil.
	gate signal.
	done wait.
	^ result + ((SnapshotScenarios respondsTo: #liveWaitOn:) ifTrue: [10] ifFalse: [0])
]

{ #category : #scenarios }
SnapshotScenarios class >> redefinedClass [
	"Module 8e: a class defined at run time, with instances, a class variable, a class-side instance variable and an old closure, reshaped on both sides, its pool changed, a second class defined and removed, all before the save; the resumed image (whose loader verified every method against its class's new shape) answers from them: 2 + 2 + 5 + 10 + 20."
	| c x blk gone |
	c := Object subclass: #LiveSnapshotSample instanceVariableNames: 'a b' classVariableNames: 'Total' category: 'Scenarios'.
	c compile: 'b ^ b'. c compile: 'b: v b := v'. c compile: 'reader ^ [b]'.
	c compile: 'total ^ Total'. c compile: 'total: v Total := v'.
	c class instanceVariableNames: 'made'.
	c class compile: 'made ^ made'. c class compile: 'made: v made := v'.
	x := c new b: 2; yourself.
	blk := x reader.
	c made: 5.
	x total: 10.
	c instanceVariableNames: 'z b'.
	c class instanceVariableNames: 'first made'.
	c addClassVarNamed: 'Extra'.
	c compile: 'extra ^ Extra'. c compile: 'extra: v Extra := v'.
	x extra: 20.
	gone := Object subclass: #LiveSnapshotGone instanceVariableNames: 'p' classVariableNames: '' category: 'Scenarios'.
	gone := nil.
	Smalltalk removeClass: (Smalltalk at: #LiveSnapshotGone).
	Smalltalk snapshot: nil.
	^ x b + blk value + c made + x total + x extra
]
