"SUnit's test case: each test* method of a concrete subclass runs in its own instance, between setUp and tearDown. Tags are method pragmas: <slow>, <device>, <expectedFailure> (a test expected to fail: its failure passes, its pass fails), selected by kajo test --tag."
Class {
	#name : #TestCase,
	#superclass : #Object,
	#instVars : [
		'testSelector'
	],
	#category : #SUnit
}

{ #category : #accessing }
TestCase >> hasTag: aString [
	^ self tags anySatisfy: [:t | t = aString asSymbol]
]

{ #category : #accessing }
TestCase >> isExpectedFailure [
	^ self hasTag: 'expectedFailure'
]

{ #category : #accessing }
TestCase >> method [
	^ self class lookupSelector: testSelector
]

{ #category : #accessing }
TestCase >> name [
	^ self class name , '>>' , testSelector
]

{ #category : #accessing }
TestCase >> run [
	| r |
	r := TestResult new.
	r runCase: self.
	^ r
]

{ #category : #accessing }
TestCase >> runCase [
	self setUp.
	[self perform: testSelector] ensure: [self tearDown]
]

{ #category : #accessing }
TestCase >> selector [
	^ testSelector
]

{ #category : #accessing }
TestCase >> setTestSelector: aSymbol [
	testSelector := aSymbol
]

{ #category : #accessing }
TestCase >> setUp [
]

{ #category : #accessing }
TestCase >> tags [
	^ (self method pragmas collect: [:p | p selector]) asArray
]

{ #category : #accessing }
TestCase >> tearDown [
]

{ #category : #assertions }
TestCase >> assert: aBoolean [
	aBoolean ifFalse: [self signalFailure: 'Assertion failed']
]

{ #category : #assertions }
TestCase >> assert: aBoolean description: aString [
	aBoolean ifFalse: [self signalFailure: aString]
]

{ #category : #assertions }
TestCase >> assert: actual equals: expected [
	actual = expected ifFalse: [
		self signalFailure: 'Expected ' , expected printString , ' but was ' , actual printString]
]

{ #category : #assertions }
TestCase >> assert: actual identicalTo: expected [
	actual == expected ifFalse: [
		self signalFailure: 'Expected the identical ' , expected printString , ' but was ' , actual printString]
]

{ #category : #assertions }
TestCase >> deny: aBoolean [
	aBoolean ifTrue: [self signalFailure: 'Denial failed']
]

{ #category : #assertions }
TestCase >> deny: aBoolean description: aString [
	aBoolean ifTrue: [self signalFailure: aString]
]

{ #category : #assertions }
TestCase >> deny: actual equals: expected [
	actual = expected ifTrue: [self signalFailure: 'Did not expect ' , expected printString]
]

{ #category : #assertions }
TestCase >> fail [
	self signalFailure: 'Test failed'
]

{ #category : #assertions }
TestCase >> fail: aString [
	self signalFailure: aString
]

{ #category : #assertions }
TestCase >> printOn: aStream [
	aStream nextPutAll: self name
]

{ #category : #assertions }
TestCase >> should: aBlock raise: anExceptionClass [
	| raised |
	raised := false.
	aBlock on: anExceptionClass do: [:e | raised := true. e return: nil].
	raised ifFalse: [self signalFailure: 'Expected ' , anExceptionClass name , ' to be signaled']
]

{ #category : #assertions }
TestCase >> shouldnt: aBlock raise: anExceptionClass [
	aBlock on: anExceptionClass do: [:e |
		self signalFailure: 'Unexpected ' , anExceptionClass name , ': ' , e messageText]
]

{ #category : #assertions }
TestCase >> signalFailure: aString [
	TestFailure new signal: aString
]

{ #category : #accessing }
TestCase class >> allTestClasses [
	^ (TestCase allSubclasses reject: [:c | c isAbstract]) asArray sort: [:a :b | a name <= b name]
]

{ #category : #accessing }
TestCase class >> consumesPragmas [
	<consumesPragmas: #(#slow #device #expectedFailure)>
	^ #(#slow #device #expectedFailure)
]

{ #category : #accessing }
TestCase class >> isAbstract [
	^ self == TestCase
]

{ #category : #accessing }
TestCase class >> selector: aSymbol [
	^ self new setTestSelector: aSymbol
]

{ #category : #accessing }
TestCase class >> suite [
	| suite |
	suite := TestSuite named: self name.
	self testSelectors do: [:s | suite addTest: (self selector: s)].
	^ suite
]

{ #category : #accessing }
TestCase class >> testSelectors [
	"The test selectors of the class and its superclasses below TestCase, sorted."
	| out c |
	out := Set new.
	c := self.
	[c notNil and: [c ~~ TestCase]] whileTrue: [
		c selectors do: [:s | ((s beginsWith: 'test') and: [s numArgs = 0]) ifTrue: [out add: s]].
		c := c superclass].
	^ out asArray sort: [:a :b | a <= b]
]
