"The target picker's window (module 9c): the known targets and their connection state, connect and disconnect the selected one, add a target by its socket and token, and a status bar with the last connection change."
Class {
	#name : #TargetPickerWindow,
	#superclass : #ToolWindow,
	#instVars : [
		'targetsTable',
		'pathView',
		'tokenView'
	],
	#category : #'Tools-Windows'
}

{ #category : #actions }
TargetPickerWindow >> command: anId [
	| row name path token |
	row := targetsTable selectedRow.
	name := (row between: 1 and: model targets size) ifTrue: [(model targets at: row) first] ifFalse: [nil].
	anId = 1 ifTrue: [name isNil ifFalse: [model connect: name token: nil]].
	anId = 2 ifTrue: [name isNil ifFalse: [model disconnect: name]].
	anId = 3 ifTrue: [model refresh].
	anId = 4 ifTrue: [
		path := (pathView text ifNil: ['']) trimmed.
		token := (tokenView text ifNil: ['']) trimmed.
		path isEmpty ifFalse: [
			tokenView text: ''.
			model add: path name: path token: (token isEmpty ifTrue: [nil] ifFalse: [token])]]
]

{ #category : #building }
TargetPickerWindow >> build [
	| toolbar |
	self makeWindow: 'Targets'.
	toolbar := Toolbar new.
	toolbar addItem: 1 title: 'Connect'; addItem: 2 title: 'Disconnect'; addItem: 3 title: 'Refresh'; addItem: 4 title: 'Add'.
	window toolbar: toolbar.
	toolbar action: [:id | self command: id].
	targetsTable := self table: #('Target' 'Socket' 'State') at: {0. 0. 560. 150}.
	targetsTable autoresize: 'width height'.
	targetsTable onDoubleClick: [:row | self command: 1].
	pathView := self textAt: {4. 156. 340. 24} editable: true.
	pathView autoresize: 'width top'.
	tokenView := self textAt: {350. 156. 206. 24} editable: true.
	tokenView autoresize: 'left top'.
	self addStatusLine
]

{ #category : #building }
TargetPickerWindow >> defaultFrame [
	^ {980. 420. 560. 210}
]

{ #category : #updating }
TargetPickerWindow >> update: anAspect [
	super update: anAspect.
	anAspect == #targets ifTrue: [targetsTable rows: model rows]
]
