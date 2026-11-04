"The test runner's model against a fake target (module 9c): the TestCase classes from the class tree, a run's test events as they arrive, the counts, and a failure run again for the debugger."
Class {
	#name : #TestRunnerModelTest,
	#superclass : #TestCase,
	#category : #'Tools-Tests'
}

{ #category : #tests }
TestRunnerModelTest >> testClassesRunEventsAndDebug [
	| c m |
	c := FakeDevClient new.
	c setFake: [:kind :args |
		kind = 'class.hierarchy' ifTrue: [{
			(JsonObject new) at: 'name' put: 'TestCase'; at: 'superclass' put: 'Object'; yourself.
			(JsonObject new) at: 'name' put: 'FooTest'; at: 'superclass' put: 'TestCase'; yourself.
			(JsonObject new) at: 'name' put: 'BarTest'; at: 'superclass' put: 'FooTest'; yourself.
			(JsonObject new) at: 'name' put: 'Foo'; at: 'superclass' put: 'Object'; yourself}] ifFalse: [
		kind = 'test.run' ifTrue: [
			c event: 'test.started' with: {'test'. 'FooTest>>testA'}.
			c event: 'test.passed' with: {'test'. 'FooTest>>testA'}.
			c event: 'test.failed' with: {'test'. 'FooTest>>testB'. 'message'. 'Assertion failed'}.
			c event: 'test.errored' with: {'test'. 'FooTest>>testC'. 'message'. 'boom'}.
			(JsonObject new) at: 'failuresAndErrors' put: 2; yourself] ifFalse: [nil]]].
	m := TestRunnerModel new client: c; yourself.
	m loadClasses.
	self assert: m classes equals: #('BarTest' 'FooTest').
	m selectClass: 'FooTest'.
	m run.
	self assert: (c sent last last at: 'filter') equals: 'FooTest>>*'.
	self assert: (m results collect: [:r | r first]) asArray equals: #('passed' 'failed' 'errored').
	self assert: m counts equals: #(1 1 1).
	self deny: m isRunning.
	self assert: (m status includesSubstring: '1 passed').
	m debug: 2.
	self assert: (c sent last last at: 'source') equals: '(FooTest selector: #testB) runCase'.
	c event: 'test.passed' with: {'test'. 'Other>>testX'}.
	self assert: m results size equals: 3
]
