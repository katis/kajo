"The test runner's window (module 9c): the target's TestCase classes, the results of a run as the test events arrive (status, test, message), Run (the selected class, or all), Debug (the selected failure run again into the debugger)."
Class {
	#name : #TestRunnerWindow,
	#superclass : #ToolWindow,
	#instVars : [
		'classesTable',
		'resultsTable'
	],
	#category : #'Tools-Windows'
}

{ #category : #building }
TestRunnerWindow >> build [
	| toolbar |
	self makeWindow: 'Test Runner'.
	toolbar := Toolbar new.
	toolbar addItem: 1 title: 'Run'; addItem: 2 title: 'Run all'; addItem: 3 title: 'Debug'.
	window toolbar: toolbar.
	toolbar action: [:id |
		id = 1 ifTrue: [model run].
		id = 2 ifTrue: [model selectClass: nil. model run].
		id = 3 ifTrue: [model debug: resultsTable selectedRow]].
	classesTable := self table: #('Test classes') at: {0. 0. 240. 450}.
	classesTable autoresize: 'height'.
	classesTable onSelect: [:row | model selectClass: ((row between: 1 and: model classes size) ifTrue: [model classes at: row] ifFalse: [nil])].
	resultsTable := self table: #('Status' 'Test' 'Message') at: {242. 0. 558. 450}.
	resultsTable autoresize: 'width height'.
	resultsTable onDoubleClick: [:row | model debug: row].
	self addStatusLine
]

{ #category : #building }
TestRunnerWindow >> defaultFrame [
	^ {160. 120. 800. 480}
]

{ #category : #updating }
TestRunnerWindow >> update: anAspect [
	super update: anAspect.
	anAspect == #classes ifTrue: [^ classesTable list: model classes].
	anAspect == #results ifTrue: [^ resultsTable rows: model results]
]
