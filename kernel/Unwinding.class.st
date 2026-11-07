"Where a Process stands while it unwinds, and the unwindings cut off (the development answers, part 3): Process>>terminateUnwinding and Context>>restartSendWith: note the ensure: or ifCurtailed: block they are about to run; a Process that waits for another to unwind (Process>>terminate, the debugger's terminate, restart and retry) reads it when the bound passes. A terminate whose unwinding was cut off at Process unwindBudgetMs is counted (cutOffCount, telemetry a host reads) and written on the Transcript with the Process and the block it stood in."
Class {
	#name : #Unwinding,
	#superclass : #Object,
	#classInstVars : [
		'lock',
		'standing',
		'cutOffs'
	],
	#category : #'Kernel-Processes'
}

{ #category : #accessing }
Unwinding class >> blockOf: aProcess [
	"The unwind block aProcess was last noted running, or nil."
	lock isNil ifTrue: [^ nil].
	^ lock critical: [standing at: aProcess ifAbsent: [nil]]
]

{ #category : #accessing }
Unwinding class >> cutOffCount [
	"How many terminations cut their Process's unwinding off at the bound since the image was built."
	^ cutOffs ifNil: [0]
]

{ #category : #accessing }
Unwinding class >> describe: aBlockOrNil [
	"Where an unwinding stood: the block's home method, or that it ran none yet."
	aBlockOrNil isNil ifTrue: [^ 'before its first unwind block'].
	^ [| m | m := aBlockOrNil method homeMethod. '[] in ' , (m ifNil: [aBlockOrNil method]) printString]
		on: Error do: [:e | aBlockOrNil printString]
]

{ #category : #accessing }
Unwinding class >> initialize [
	lock := Mutex new.
	standing := IdentityDictionary new.
	cutOffs := 0
]

{ #category : #noting }
Unwinding class >> cutOff: aProcess after: aMilliseconds [
	"aProcess was ended where it stood, its unwinding not run to its end: counted, written on the Transcript with the block it stood in. Answers the description."
	| text n |
	lock isNil ifTrue: [self initialize].
	text := 'Process ' , aProcess id printString , ' terminated: its unwinding was cut off after ' , aMilliseconds printString
		, ' ms ' , (self describe: (self blockOf: aProcess)).
	n := lock critical: [standing removeKey: aProcess ifAbsent: [nil]. cutOffs := (cutOffs ifNil: [0]) + 1].
	Transcript showLine: text , ' (' , n printString , ' cut off so far)'.
	^ text
]

{ #category : #noting }
Unwinding class >> forget: aProcess [
	lock isNil ifTrue: [^ nil].
	^ lock critical: [standing removeKey: aProcess ifAbsent: [nil]]
]

{ #category : #noting }
Unwinding class >> note: aBlock for: aProcess [
	"aProcess is about to run aBlock while it unwinds."
	lock isNil ifTrue: [self initialize].
	^ lock critical: [standing at: aProcess put: aBlock]
]
