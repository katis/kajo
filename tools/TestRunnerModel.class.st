"A test runner's model (module 9c): the target's TestCase classes, run one or all (test.run with a filter), the test.* events shown as they arrive (passed, failed, errored with the message), the counts, and a failing test run again on demand without SUnit's handler, so its error stops it for the debugger."
Class {
	#name : #TestRunnerModel,
	#superclass : #ToolModel,
	#instVars : [
		'classes',
		'selectedClass',
		'results',
		'running',
		'listener'
	],
	#category : #'Tools-Models'
}

{ #category : #accessing }
TestRunnerModel >> classes [
	^ classes ifNil: [#()]
]

{ #category : #accessing }
TestRunnerModel >> counts [
	"{passed. failed. errored}."
	| p f e |
	p := f := e := 0.
	self results do: [:r |
		r first = 'passed' ifTrue: [p := p + 1].
		r first = 'failed' ifTrue: [f := f + 1].
		r first = 'errored' ifTrue: [e := e + 1]].
	^ {p. f. e}
]

{ #category : #accessing }
TestRunnerModel >> isRunning [
	^ running == true
]

{ #category : #accessing }
TestRunnerModel >> results [
	"{status. test name. message} of each test of the last run, in order."
	^ results ifNil: [#()]
]

{ #category : #accessing }
TestRunnerModel >> selectedClass [
	^ selectedClass
]

{ #category : #closing }
TestRunnerModel >> closed [
	listener isNil ifFalse: [client removeListener: listener]
]

{ #category : #initialization }
TestRunnerModel >> client: aDevClient [
	super client: aDevClient.
	listener := aDevClient on: '*' do: [:e | self noteEvent: e]
]

{ #category : #running }
TestRunnerModel >> debug: anIndex [
	"Run a failing test again without SUnit's handler: its error stops it for the debugger (process.stopped)."
	| name i |
	(anIndex between: 1 and: self results size) ifFalse: [^ self].
	name := (results at: anIndex) at: 2.
	i := name indexOfSubstring: '>>'.
	i = 0 ifTrue: [^ self].
	self request: 'evaluate'
		args: {'source'. '(' , (name copyFrom: 1 to: i - 1) , ' selector: #' , (name copyFrom: i + 2 to: name byteSize) , ') runCase'}
		then: [:r | self status: name , ' passed this time']
]

{ #category : #running }
TestRunnerModel >> loadClasses [
	"Every concrete TestCase subclass of the target, by the class tree."
	self request: 'class.hierarchy' args: #() then: [:r | | sup out |
		sup := Dictionary new.
		r do: [:e | sup at: (e at: 'name') put: (e at: 'superclass')].
		out := OrderedCollection new.
		r do: [:e | | s |
			s := e at: 'superclass'.
			[s notNil and: [s ~= 'TestCase']] whileTrue: [s := sup at: s ifAbsent: [nil]].
			(s notNil and: [(e at: 'name') ~= 'TestCase']) ifTrue: [out add: (e at: 'name')]].
		classes := out asArray sort: [:a :b | a <= b].
		self changed: #classes]
]

{ #category : #running }
TestRunnerModel >> noteEvent: anEvent [
	| k |
	running == true ifFalse: [^ self].
	k := anEvent at: 'kind'.
	(k beginsWith: 'test.') ifFalse: [^ self].
	k = 'test.started' ifTrue: [^ self].
	results add: {k copyFrom: 6 to: k byteSize. anEvent at: 'test'. (anEvent at: 'message') ifNil: ['']}.
	self changed: #results
]

{ #category : #running }
TestRunnerModel >> run [
	"The selected class's tests, or all of them."
	self runFilter: (selectedClass ifNil: [nil] ifNotNil: [:c | c , '>>*'])
]

{ #category : #running }
TestRunnerModel >> runFilter: aFilterOrNil [
	results := OrderedCollection new.
	running := true.
	self status: 'running ' , (aFilterOrNil ifNil: ['every test']).
	self changed: #results.
	self request: 'test.run' args: {'filter'. aFilterOrNil} then: [:r | | c |
		running := false.
		c := self counts.
		self status: c first printString , ' passed, ' , (c at: 2) printString , ' failed, ' , (c at: 3) printString , ' errors'.
		self changed: #results]
]

{ #category : #running }
TestRunnerModel >> selectClass: aName [
	selectedClass := aName
]
