"Processes run in parallel on the VM's workers; Semaphores, Mutex, Monitor, SharedQueue, Delay."
Class {
	#name : #ProcessTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
ProcessTest >> testActiveProcess [
	| p |
	p := ProcessorScheduler activeProcess.
	self assert: p class == Process.
	self assert: p state == #running.
	self deny: p isTerminated
]

{ #category : #accessing }
ProcessTest >> testDelay [
	| t0 |
	t0 := Smalltalk microsecondClock.
	(Delay forMilliseconds: 20) wait.
	self assert: Smalltalk microsecondClock - t0 >= 15000
]

{ #category : #accessing }
ProcessTest >> testForkAndSemaphore [
	| s result |
	s := Semaphore new.
	[result := 6 * 7. s signal] fork.
	s wait.
	self assert: result = 42
]

{ #category : #accessing }
ProcessTest >> testManyProcessesWithASharedQueue [
	| q sum |
	q := SharedQueue new.
	1 to: 10 do: [:i | [q nextPut: i * i] fork].
	sum := 0.
	10 timesRepeat: [sum := sum + q next].
	self assert: sum = 385
]

{ #category : #accessing }
ProcessTest >> testMonitorWaitAndSignal [
	| mon ready value done |
	mon := Monitor new.
	ready := false.
	done := Semaphore new.
	[mon critical: [[ready] whileFalse: [mon wait]. value := 7]. done signal] fork.
	ProcessorScheduler yield.
	mon critical: [ready := true. mon signal].
	done wait.
	self assert: value = 7
]

{ #category : #accessing }
ProcessTest >> testMutexIsReentrant [
	| m r |
	m := Mutex new.
	r := m critical: [m critical: [5]].
	self assert: r = 5
]

{ #category : #accessing }
ProcessTest >> testMutexProtectsACounter [
	| m counter done |
	m := Mutex new.
	counter := 0.
	done := Semaphore new.
	1 to: 4 do: [:k | [1 to: 200 do: [:i | m critical: [counter := counter + 1]]. done signal] fork].
	4 timesRepeat: [done wait].
	self assert: counter = 800
]

{ #category : #accessing }
ProcessTest >> testTerminate [
	| s p |
	s := Semaphore new.
	p := [s wait] fork.
	ProcessorScheduler yield.
	p terminate.
	self assert: p isTerminated
]
