"An inspector's window (module 9c): the object's slots (name, class, value), its printString, and a workspace with self bound to it; double-click a slot to inspect it, Back to return. Closing it releases every handle the inspector was given."
Class {
	#name : #InspectorWindow,
	#superclass : #ToolWindow,
	#instVars : [
		'slotsTable',
		'valueView',
		'workspaceView'
	],
	#category : #'Tools-Windows'
}

{ #category : #building }
InspectorWindow >> build [
	| toolbar |
	self makeWindow: model title.
	toolbar := Toolbar new.
	toolbar addItem: 1 title: 'Back'.
	window toolbar: toolbar.
	toolbar action: [:id | model back].
	slotsTable := self table: #('Slot' 'Class' 'Value') at: {0. 0. 520. 220}.
	slotsTable autoresize: 'width height'.
	slotsTable onDoubleClick: [:row | model dive: row].
	valueView := self textAt: {0. 222. 520. 90} editable: false.
	valueView autoresize: 'width top'.
	workspaceView := self textAt: {0. 314. 520. 120} editable: true.
	workspaceView autoresize: 'width top'.
	workspaceView bindKeys: #('cmd-d' 'cmd-p' 'cmd-i').
	workspaceView onKey: [:k | self evaluateIn: workspaceView with: model workspace key: k].
	self addStatusLine
]

{ #category : #building }
InspectorWindow >> defaultFrame [
	^ {260. 140. 520. 460}
]

{ #category : #updating }
InspectorWindow >> update: anAspect [
	super update: anAspect.
	anAspect == #object ifTrue: [
		window title: model title.
		valueView text: ((model object at: 'value') ifNil: ['']).
		slotsTable rows: (model slots collect: [:s | {s at: 'name'. s at: 'class'. s at: 'value'}]) asArray]
]
