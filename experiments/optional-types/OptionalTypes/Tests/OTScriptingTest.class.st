"Question 9's demonstration as a test: protocols made by code, a workspace expression checked against them, the protocols replaced and the expression rechecked."
Class {
	#name : #OTScriptingTest,
	#superclass : #TestCase
}

{ #category : #tests }
OTScriptingTest >> testProtocolsMadeByCodeAndReplaced [
	| ann checker app mc keys |
	ann := OTAnnotations fromString: 'class SequenceableCollection[E]
method first ^<E>'.
	checker := OTChecker on: ann.
	OTScripting register: OTScripting dictionary in: ann.
	app := Dictionary new at: 'app' put: (OTProtocolType named: 'Mail.Application'); yourself.
	mc := checker checkSource: 'app mailboxes first messages first subject' named: 'doit' bindings: app.
	self assert: mc diagnostics isEmpty.
	self assert: mc inferredResult printString equals: 'String'.
	mc := checker checkSource: 'app mailboxes first messages first sender: ''me''' named: 'doit2' bindings: app.
	self assert: (mc diagnostics collect: [:d | d text]) asArray equals: #('Mail.Message does not answer #sender:').
	keys := OTScripting register: OTScripting dictionaryVersion2 in: ann.
	(checker recheck: (keys inject: Set new into: [:s :k | s addAll: (checker invalidate: k); yourself])) do: [:x | nil].
	self assert: ((checker results at: 'doit') inferredResult) printString equals: 'Mail.RichText'
]
