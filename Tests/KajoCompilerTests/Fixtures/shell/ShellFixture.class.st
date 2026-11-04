"Module 9a's host-surface tests (Tests/KajoCompilerTests/ShellTests.swift): Smalltalk the Swift test shell drives."
Class {
	#name : #ShellFixture,
	#superclass : #Object,
	#classInstVars : [
		'window',
		'label',
		'button',
		'count',
		'times',
		'probe'
	],
	#category : #'Shell-Tests'
}

{ #category : #building }
ShellFixture class >> buildCounter [
	"A window with a label and a button whose action counts presses into the label. Answers the button's handle."
	count := 0.
	times := OrderedCollection new.
	window := Window new.
	window title: 'Counter'.
	label := window add: Label new.
	label x: 10 y: 10 width: 200 height: 20.
	label text: '0'.
	button := window add: Button new.
	button title: 'Press'.
	button action: [count := count + 1. label text: count printString].
	window show.
	^ button handle
]

{ #category : #building }
ShellFixture class >> labelHandle [
	^ label handle
]

{ #category : #building }
ShellFixture class >> count [
	^ count
]

{ #category : #building }
ShellFixture class >> listen [
	"Synthetic events set the label to their value and remember their time; frame events move a probe view."
	probe := window add: View new.
	UIEventLoop onSynthetic: [:e | times add: e time. label text: e value printString].
	UIEventLoop onFrame: [:e | probe moveToX: e value \\ 300 y: 40].
	^ probe handle
]

{ #category : #building }
ShellFixture class >> lastTime [
	^ times isEmpty ifTrue: [0] ifFalse: [times last]
]

{ #category : #building }
ShellFixture class >> fromBackground [
	"Run on a background worker: the first view call hops to main; answers the worker it ended on."
	| l |
	l := Label new.
	l text: 'from the background'.
	^ ProcessorScheduler workerId
]

{ #category : #building }
ShellFixture class >> dropViews: n [
	n timesRepeat: [View new].
	Smalltalk garbageCollect.
	^ n
]

{ #category : #building }
ShellFixture class >> hog [
	| x |
	x := 0.
	[true] whileTrue: [x := x + 1]
]

{ #category : #tests }
ShellFixture class >> runViewTests [
	"The kernel's ViewTest against the shell (the event stream goes to the host)."
	^ TestRunner new runFilter: 'ViewTest' tag: nil
]
