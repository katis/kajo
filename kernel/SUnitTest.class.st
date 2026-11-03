"The harness on itself: outcomes, expected failures, should:raise:."
Class {
	#name : #SUnitTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
SUnitTest >> testOutcomes [
	| r |
	r := (SUnitSample selector: #testPass) run.
	self assert: r passed size = 1.
	r := (SUnitSample selector: #testFail) run.
	self assert: r failures size = 1.
	r := (SUnitSample selector: #testError) run.
	self assert: r errors size = 1.
	r := (SUnitSample selector: #testExpectedFailure) run.
	self assert: r passed size = 1.
	r := (SUnitSample selector: #testUnexpectedPass) run.
	self assert: r failures size = 1
]

{ #category : #accessing }
SUnitTest >> testSetUpAndTearDownRun [
	| t |
	t := SUnitSample selector: #testPass.
	t run.
	self assert: t log asArray = #(#setUp #testPass #tearDown)
]

{ #category : #accessing }
SUnitTest >> testShouldRaise [
	self should: [1 / 0] raise: ZeroDivide.
	self shouldnt: [1 / 1] raise: ZeroDivide.
	self assert: ((SUnitSample selector: #testShouldFails) run) failures size = 1
]

{ #category : #accessing }
SUnitTest >> testSuite [
	| r |
	r := SUnitSample suite run.
	self assert: r runCount = SUnitSample testSelectors size.
	self assert: r printString notEmpty
]

{ #category : #accessing }
SUnitTest >> testFilterPatterns [
	| runner |
	runner := TestRunner new.
	self assert: (runner name: 'FooTest>>testBar' matches: 'Bar').
	self assert: (runner name: 'FooTest>>testBar' matches: 'Foo*Bar').
	self deny: (runner name: 'FooTest>>testBar' matches: 'Foo*Baz').
	self assert: (runner name: 'FooTest>>testBar' matches: '*')
]
