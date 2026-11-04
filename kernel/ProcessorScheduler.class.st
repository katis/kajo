"The scheduler's protocol, class side: the VM schedules (module 3) and there is no instance (Smalltalk-80's global Processor is ProcessorScheduler here)."
Class {
	#name : #ProcessorScheduler,
	#superclass : #Object,
	#category : #'Kernel-Processes'
}

{ #category : #accessing }
ProcessorScheduler class >> activeProcess [
	<primitive: 33>
	^ nil
]

{ #category : #accessing }
ProcessorScheduler class >> detachFromMain [
	<primitive: 32>
	^ nil
]

{ #category : #accessing }
ProcessorScheduler class >> primAllProcesses [
	"Every live Process (module 9b, the protocol's process.list), in an Array padded with nil."
	<primitive: 162>
	^ #()
]

{ #category : #accessing }
ProcessorScheduler class >> terminateActive [
	self activeProcess terminate
]

{ #category : #accessing }
ProcessorScheduler class >> userBackgroundPriority [
	^ 0
]

{ #category : #accessing }
ProcessorScheduler class >> userInterruptPriority [
	^ 2
]

{ #category : #accessing }
ProcessorScheduler class >> userSchedulingPriority [
	^ 1
]

{ #category : #accessing }
ProcessorScheduler class >> workerId [
	<primitive: 34>
	^ 0
]

{ #category : #accessing }
ProcessorScheduler class >> yield [
	<primitive: 21>
	^ nil
]
