"The transcript's model (module 9c): the transcript events of every connected target, each line marked with its target when more than one is connected; the last 5000 lines are kept."
Class {
	#name : #TranscriptModel,
	#superclass : #ToolModel,
	#instVars : [
		'lines',
		'last',
		'targets'
	],
	#category : #'Tools-Models'
}

{ #category : #accessing }
TranscriptModel >> lastLine [
	^ last
]

{ #category : #accessing }
TranscriptModel >> lines [
	^ lines ifNil: [#()]
]

{ #category : #lines }
TranscriptModel >> add: aString from: aClient [
	| line |
	lines isNil ifTrue: [lines := OrderedCollection new].
	line := (targets ifNil: [0]) > 1 ifTrue: [aClient name , ': ' , aString] ifFalse: [aString].
	lines add: line.
	lines size > 5000 ifTrue: [lines removeFirst: 1000].
	last := line.
	self changed: #line
]

{ #category : #lines }
TranscriptModel >> listenTo: aClient [
	"aClient's transcript events from now on."
	targets := (targets ifNil: [0]) + 1.
	aClient on: 'transcript' do: [:e | self add: ((e at: 'text') ifNil: ['']) from: aClient]
]
