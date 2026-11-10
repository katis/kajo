Class {
	#name : #TranscriptTest,
	#superclass : #TestCase
}

{ #category : #accessing }
TranscriptTest >> testAFailingDisplayStringLeavesTheTranscriptUsable [
	"The review fixes, item 7: show: makes its text outside the lock, so an object whose printOn: fails, shown by a Process that does not handle the error, is reported and ended and the next line still goes out. Before, the report's own Transcript line waited for the lock its Process held, forever."
	| done deadline |
	done := false.
	[Transcript show: TranscriptTestProbe new] fork.
	[Transcript showLine: 'after the failing show'. done := true] fork.
	deadline := Smalltalk microsecondClock + 30000000.
	[done or: [Smalltalk microsecondClock > deadline]] whileFalse: [(Delay forMilliseconds: 10) wait].
	self assert: done.
	done := false.
	[Transcript showLine: 42. done := true] fork.
	deadline := Smalltalk microsecondClock + 30000000.
	[done or: [Smalltalk microsecondClock > deadline]] whileFalse: [(Delay forMilliseconds: 10) wait].
	self assert: done
]

{ #category : #accessing }
TranscriptTest >> testShowAndContents [
	Transcript flush.
	Transcript show: 'abc'; show: 42; print: 'q'.
	self assert: Transcript contents = 'abc42''q'''.
	Transcript cr.
	self assert: Transcript contents isEmpty
]
