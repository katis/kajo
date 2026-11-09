"The development answers' tests (Tests/KajoCompilerTests/DevelopmentAnswersTests.swift): Processes that die in an unhandled error, for hosts that report and end them and hosts that stop them for the debugger."
Class {
	#name : #AnswersProbe,
	#superclass : #Object,
	#classInstVars : [
		'last',
		'result',
		'ended',
		'synthetic'
	]
}

{ #category : #failing }
AnswersProbe class >> fill: n [
	"n Processes that each die in an unhandled error; answers how many were started."
	1 to: n do: [:i | [AnswersSample new compute] forkAt: 1].
	^ n
]

{ #category : #failing }
AnswersProbe class >> forkFailure [
	"A Process that dies in a doesNotUnderstand: (AnswersSample>>missingPart); when it goes on, result is what compute answered. Answers its id."
	result := nil.
	last := [result := AnswersSample new compute] forkAt: 1.
	^ last id
]

{ #category : #failing }
AnswersProbe class >> forkFailureAndWait [
	"A batch host's rule: the forked Process's unhandled error is reported and the Process ends. Waits for that at most 10 000 Delays of a millisecond; answers whether it ended."
	| n |
	self forkFailure.
	n := 0.
	[last isTerminated or: [n >= 10000]] whileFalse: [(Delay forMilliseconds: 1) wait. n := n + 1].
	ended := last isTerminated.
	^ ended
]

{ #category : #failing }
AnswersProbe class >> recordForkEnded [
	"For KernelRun's host (the image build's): nil unless the last forked Process ended."
	^ (self forkFailureAndWait) ifTrue: [true] ifFalse: [nil]
]

{ #category : #accessing }
AnswersProbe class >> ended [
	^ ended
]

{ #category : #accessing }
AnswersProbe class >> lastId [
	^ last isNil ifTrue: [0] ifFalse: [last id]
]

{ #category : #accessing }
AnswersProbe class >> lastIsStopped [
	^ last notNil and: [Debugger isStoppedProcessId: last id]
]

{ #category : #accessing }
AnswersProbe class >> lastIsTerminated [
	^ last notNil and: [last isTerminated]
]

{ #category : #accessing }
AnswersProbe class >> result [
	^ result
]

{ #category : #accessing }
AnswersProbe class >> stopCount [
	^ Debugger stops size
]

{ #category : #accessing }
AnswersProbe class >> refusedStops [
	^ Debugger refusedStops
]

{ #category : #accessing }
AnswersProbe class >> stopCap [
	^ Debugger stopCap
]

{ #category : #accessing }
AnswersProbe class >> stoppedErrorCount [
	^ (Debugger stops select: [:s | s reason = 'error']) size
]

{ #category : #'event loop' }
AnswersProbe class >> breakSyntheticEvents [
	"From now on the event loop's synthetic action fails on the event whose value is 1 (an error in an app's handler) and counts every other one."
	synthetic := 0.
	UIEventLoop onSynthetic: [:e |
		e value = 1 ifTrue: [AnswersSample new compute].
		synthetic := synthetic + 1].
	^ true
]

{ #category : #'event loop' }
AnswersProbe class >> loopProcessId [
	^ UIEventLoop process isNil ifTrue: [0] ifFalse: [UIEventLoop process id]
]

{ #category : #'event loop' }
AnswersProbe class >> syntheticHandled [
	^ synthetic ifNil: [0]
]

{ #category : #'event loop' }
AnswersProbe class >> handOvers [
	^ UIEventLoop handOverCount
]
