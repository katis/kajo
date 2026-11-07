"kajo test is a batch host (the development answers): a forked Process's unhandled error is reported and the Process ends, so the test run never waits for a debugger."
Class {
	#name : #AnswersBatchTest,
	#superclass : #TestCase,
	#category : #'Answers-Tests'
}

{ #category : #tests }
AnswersBatchTest >> testAForkedProcessDyingInAnErrorEnds [
	self assert: AnswersProbe forkFailureAndWait
]
