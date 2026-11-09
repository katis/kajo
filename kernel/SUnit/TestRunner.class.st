"What kajo test runs: every concrete TestCase's tests, filtered, between run.started and run.finished."
Class {
	#name : #TestRunner,
	#superclass : #Object,
	#instVars : [
		'result'
	]
}

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
	| cases t0 |
	cases := OrderedCollection new.
	TestCase allTestClasses do: [:c |
		c testSelectors do: [:s | | t |
			t := c selector: s.
			((filter isNil or: [self name: t name matches: filter])
				and: [tag isNil or: [t hasTag: tag]]) ifTrue: [cases add: t]]].
	result := TestResult new beEmitting; yourself.
	self emitEvent: 'run.started' fields: {'total'. cases size. 'filter'. filter. 'tag'. tag}.
	t0 := Smalltalk microsecondClock.
	cases do: [:t | result runCase: t].
	Transcript flush.
	self emitEvent: 'run.finished' fields: {'total'. cases size. 'passed'. result passed size. 'failed'. result failures size.
		'errored'. result errors size. 'us'. Smalltalk microsecondClock - t0}.
	^ result failures size + result errors size
]
