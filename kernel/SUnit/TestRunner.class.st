"What kajo test runs: every concrete TestCase's tests, filtered, between run.started and run.finished."
Class {
	#name : #TestRunner,
	#superclass : #Object,
	#instVars : [
		'result'
	]
}

{ #category : #accessing }
TestRunner >> casesFilter: filter tag: tag tests: names [
	"The tests a run selects: every concrete TestCase's tests whose name matches filter, that carry tag and, when names is not nil, whose name is one of names."
	| cases |
	cases := OrderedCollection new.
	TestCase allTestClasses do: [:c |
		c testSelectors do: [:s | | t |
			t := c selector: s.
			((filter isNil or: [self name: t name matches: filter])
				and: [(tag isNil or: [t hasTag: tag])
					and: [names isNil or: [names includes: t name]]]) ifTrue: [cases add: t]]].
	^ cases
]

{ #category : #accessing }
TestRunner >> listFilter: filter tag: tag tests: names [
	"The selected tests without running them (gate speed): a test.listed event each, then run.listed with their number. Answers 0."
	| cases |
	cases := self casesFilter: filter tag: tag tests: names.
	cases do: [:t | self emitEvent: 'test.listed' fields: {'test'. t name. 'class'. t class name. 'selector'. t selector. 'tags'. t tags}].
	self emitEvent: 'run.listed' fields: {'total'. cases size. 'filter'. filter. 'tag'. tag}.
	^ 0
]

{ #category : #accessing }
TestRunner >> name: aString matches: pattern [
	"A pattern with * wildcards matches the whole name; without, any part of it."
	| pieces i |
	(pattern includes: $*) ifFalse: [^ aString includesSubstring: pattern].
	pieces := pattern splitOn: '*'.
	(aString beginsWith: pieces first) ifFalse: [^ false].
	(aString endsWith: pieces last) ifFalse: [^ false].
	i := 1.
	pieces do: [:p | p isEmpty ifFalse: [
		i := aString indexOfSubstring: p startingAt: i.
		i = 0 ifTrue: [^ false].
		i := i + p byteSize]].
	^ true
]

{ #category : #accessing }
TestRunner >> result [
	^ result
]

{ #category : #accessing }
TestRunner >> runFilter: filter tag: tag [
	^ self runFilter: filter tag: tag tests: nil
]

{ #category : #accessing }
TestRunner >> runFilter: filter tag: tag tests: names [
	| cases t0 |
	cases := self casesFilter: filter tag: tag tests: names.
	result := TestResult new beEmitting; yourself.
	self emitEvent: 'run.started' fields: {'total'. cases size. 'filter'. filter. 'tag'. tag}.
	t0 := Smalltalk microsecondClock.
	cases do: [:t | result runCase: t].
	Transcript flush.
	self emitEvent: 'run.finished' fields: {'total'. cases size. 'passed'. result passed size. 'failed'. result failures size.
		'errored'. result errors size. 'us'. Smalltalk microsecondClock - t0}.
	^ result failures size + result errors size
]
