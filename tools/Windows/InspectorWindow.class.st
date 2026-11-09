"An inspector's window (module 9c): the object's slots (name, class, value), its printString, and a workspace with self bound to it; double-click a slot to inspect it, Back to return. Closing it releases every handle the inspector was given. Since the pointersTo: follow-up the slots table's context menu finds the objects pointing to the inspected object or to the selected slot's value."
Class {
	#name : #InspectorWindow,
	#superclass : #ToolWindow,
	#instVars : [
		'slotsTable',
		'valueView',
		'workspaceView'
	]
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
	slotsTable onSelect: [:row | model selectSlot: row].
	self slotsMenu ifNotNil: [:m | slotsTable contextMenu: m].
	valueView := self textAt: {0. 222. 520. 90} editable: false.
	valueView autoresize: 'width top'.
	workspaceView := self textAt: {0. 314. 520. 120} editable: true.
	workspaceView autoresize: 'width top'.
	self pane: workspaceView keys: (DevTools keysOfPane: 'Inspector evaluation pane')
		action: [:k | self key: k in: workspaceView with: model workspace].
	self addStatusLine
]

{ #category : #building }
InspectorWindow >> defaultFrame [
	^ {260. 140. 520. 460}
]

{ #category : #building }
InspectorWindow >> slotsMenu [
	"The slots table's context menu (the pointersTo: follow-up): Objects pointing to it, for the inspected object and for the selected slot's value, each opening a new inspector. nil on a host without menus."
	DevTools menusSupported ifFalse: [^ nil].
	^ DevTools menu: 'Inspector' items: self class slotsMenuItems action: [:id | self slotsMenuItem: id]
]

{ #category : #building }
InspectorWindow >> slotsMenuItem: anId [
	anId = 41 ifTrue: [^ model pointersToObject].
	anId = 42 ifTrue: [^ model pointersToSelectedSlot]
]

{ #category : #updating }
InspectorWindow >> update: anAspect [
	super update: anAspect.
	anAspect == #object ifTrue: [
		window title: model title.
		valueView text: ((model object at: 'value') ifNil: ['']).
		slotsTable rows: (model slots collect: [:s | {s at: 'name'. s at: 'class'. s at: 'value'}]) asArray]
]

{ #category : #building }
InspectorWindow class >> slotsMenuItems [
	"id, title, key: the slots table's context menu."
	^ #(#(41 'Objects pointing to it' '') #(42 'Objects pointing to the slot''s value' ''))
]
