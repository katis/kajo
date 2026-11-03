"The outcome of running tests. The runner's result emits the test events; a result made by TestCase>>run or TestSuite>>run does not."
Class {
	#name : #TestResult,
	#superclass : #Object,
	#instVars : [
		'passed',
		'failures',
		'errors',
		'emitting'
	],
	#category : #SUnit
}

{ #category : #accessing }
TestResult class >> new [
	^ self basicNew setUp
]

{ #category : #accessing }
TestResult >> setUp [
	passed := OrderedCollection new.
	failures := OrderedCollection new.
	errors := OrderedCollection new.
	emitting := false
]

{ #category : #accessing }
TestResult >> beEmitting [
	emitting := true
]

{ #category : #accessing }
TestResult >> emit: kind fields: anArray [
	emitting ifTrue: [self emitEvent: kind fields: anArray]
]

{ #category : #accessing }
TestResult >> passed [
	^ passed
]

{ #category : #accessing }
TestResult >> failures [
	^ failures
]

{ #category : #accessing }
TestResult >> errors [
	^ errors
]

{ #category : #accessing }
TestResult >> runCount [
	^ passed size + failures size + errors size
]

{ #category : #accessing }
TestResult >> hasPassed [
	^ failures isEmpty and: [errors isEmpty]
]

{ #category : #accessing }
TestResult >> runCase: aTestCase [
	"Run one test and emit test.started, then test.passed, test.failed (with the message and the frames) or test.errored."
	| t0 outcome info frames fields |
	self emit: 'test.started' fields: (self fieldsFor: aTestCase).
	t0 := Smalltalk microsecondClock.
	outcome := #passed.
	[[aTestCase runCase]
		on: TestFailure do: [:e | outcome := #failed. info := e. frames := e frames. e return: nil]]
			on: Error do: [:e | outcome := #errored. info := e. frames := e frames. e return: nil].
	aTestCase isExpectedFailure ifTrue: [
		outcome == #passed
			ifTrue: [outcome := #failed. info := TestFailure new messageText: 'Expected a failure, but the test passed'. frames := #()]
			ifFalse: [outcome := #passed]].
	fields := (self fieldsFor: aTestCase) , {'us'. Smalltalk microsecondClock - t0}.
	outcome == #passed ifTrue: [
		passed add: aTestCase.
		aTestCase isExpectedFailure ifTrue: [fields := fields , {'expectedFailure'. true}].
		^ self emit: 'test.passed' fields: fields].
	fields := fields , {'message'. info messageText. 'exception'. info class name. 'frames'. frames}.
	outcome == #failed ifTrue: [
		failures add: aTestCase.
		^ self emit: 'test.failed' fields: fields].
	errors add: aTestCase.
	self emit: 'test.errored' fields: fields
]

{ #category : #accessing }
TestResult >> fieldsFor: aTestCase [
	^ {'test'. aTestCase name. 'class'. aTestCase class name. 'selector'. aTestCase selector. 'tags'. aTestCase tags}
]

{ #category : #accessing }
TestResult >> printOn: aStream [
	aStream print: self runCount; nextPutAll: ' run, '; print: passed size; nextPutAll: ' passed, ';
		print: failures size; nextPutAll: ' failed, '; print: errors size; nextPutAll: ' errors'
]
