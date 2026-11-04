"signal, on:do:, return:, resume:, retry, pass, outer, ensure:, ifCurtailed:, exception sets, non-local return through unwind blocks."
Class {
	#name : #ExceptionTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
ExceptionTest >> helperThatFails [
	^ 1 / 0
]

{ #category : #accessing }
ExceptionTest >> returnThroughEnsure: log [
	#(1 2 3) do: [:x | [log add: #body. x = 1 ifTrue: [^ 10]] ensure: [log add: #ensure]].
	^ 0
]

{ #category : #accessing }
ExceptionTest >> testEnsure [
	| log r |
	log := OrderedCollection new.
	r := [log add: 1. 2] ensure: [log add: 3].
	self assert: r = 2.
	self assert: log asArray = #(1 3).
	log := OrderedCollection new.
	r := [[log add: 1. Error signal. log add: 2] ensure: [log add: 3]] on: Error do: [:e | log add: 4. 5].
	self assert: r = 5.
	self assert: log asArray = #(1 4 3)
]

{ #category : #accessing }
ExceptionTest >> testExceptionDescription [
	self assert: ([Error signal: 'm'] on: Error do: [:e | e messageText]) = 'm'.
	self assert: ([Error new signal] on: Error do: [:e | e messageText]) = 'Error'.
	self assert: ([nil foo] on: MessageNotUnderstood do: [:e | e messageText]) = 'nil does not understand #foo'
]

{ #category : #accessing }
ExceptionTest >> testFramesAreTheSignalersStack [
	| frames |
	frames := [self helperThatFails] on: ZeroDivide do: [:e | e frames].
	self assert: (frames first includesSubstring: 'Integer').
	self assert: (frames anySatisfy: [:f | f = 'ExceptionTest>>helperThatFails'])
]

{ #category : #accessing }
ExceptionTest >> testHandlerSelection [
	| r |
	r := [[1 / 0] on: MessageNotUnderstood do: [:e | #wrong]] on: ZeroDivide do: [:e | #right].
	self assert: r == #right.
	r := [1 / 0] on: ZeroDivide, MessageNotUnderstood do: [:e | #set].
	self assert: r == #set.
	r := [nil foo] on: ZeroDivide, MessageNotUnderstood do: [:e | #set].
	self assert: r == #set.
	r := [1 / 0] on: Error do: [:e | e class].
	self assert: r == ZeroDivide
]

{ #category : #accessing }
ExceptionTest >> testIfCurtailed [
	| log |
	log := OrderedCollection new.
	[log add: 1] ifCurtailed: [log add: 2].
	self assert: log asArray = #(1).
	[[Error signal] ifCurtailed: [log add: 3]] on: Error do: [:e | nil].
	self assert: log asArray = #(1 3)
]

{ #category : #accessing }
ExceptionTest >> testNestedEnsureOrder [
	| log |
	log := OrderedCollection new.
	[[[Error signal] ensure: [log add: 1]] ensure: [log add: 2]] on: Error do: [:e | log add: 0].
	self assert: log asArray = #(0 1 2)
]

{ #category : #accessing }
ExceptionTest >> testNonLocalReturnRunsEnsureBlocks [
	| log |
	log := OrderedCollection new.
	self assert: (self returnThroughEnsure: log) = 10.
	self assert: log asArray = #(#body #ensure)
]

{ #category : #accessing }
ExceptionTest >> testPassAndOuter [
	| r log |
	r := [[Error signal: 'x'] on: Error do: [:e | e pass]] on: Error do: [:e | 'outer ' , e messageText].
	self assert: r = 'outer x'.
	log := OrderedCollection new.
	r := [[(Warning signal: 'w') + 1] on: Warning do: [:e | log add: (e outer). e resume: 100]] on: Warning do: [:e | e resume: 5].
	self assert: log asArray = #(5).
	self assert: r = 101
]

{ #category : #accessing }
ExceptionTest >> testResumingANonResumableErrorIsAnError [
	| r |
	r := [[Error signal] on: Error do: [:e | e resume: 3]] on: IllegalResumeAttempt do: [:e | #illegal].
	self assert: r == #illegal
]

{ #category : #accessing }
ExceptionTest >> testRetry [
	| count r |
	count := 0.
	r := [count := count + 1. count < 3 ifTrue: [Error signal]. count] on: Error do: [:e | e retry].
	self assert: r = 3
]

{ #category : #accessing }
ExceptionTest >> testReturnAndResume [
	| r |
	r := [Error signal: 'boom'. 5] on: Error do: [:e | e messageText].
	self assert: r = 'boom'.
	r := [(Warning signal: 'w') + 1] on: Warning do: [:e | e resume: 41].
	self assert: r = 42.
	r := [Error signal. 5] on: Error do: [:e | e return: 7].
	self assert: r = 7.
	r := [ZeroDivide new signal. 5] on: ZeroDivide do: [:e | 9].
	self assert: r = 9
]

{ #category : #accessing }
ExceptionTest >> testSignalInHandlerGoesOutward [
	| r |
	r := [[Error signal: 'a'] on: Error do: [:e | Error signal: 'b']] on: Error do: [:e | e messageText].
	self assert: r = 'b'
]

{ #category : #accessing }
ExceptionTest >> testUnhandledNotificationAnswersNil [
	self assert: Notification signal isNil.
	self assert: (Warning signal: 'ignored') isNil
]
