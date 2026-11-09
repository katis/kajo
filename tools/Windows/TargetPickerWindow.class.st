"The target picker's window (module 9c): the known targets and their connection state, connect and disconnect the selected one, pair the selected one (module 9d: the shell takes its token in a secure field of its own, never this image), add a target by its address, and a status bar with the last connection change."
Class {
	#name : #TargetPickerWindow,
	#superclass : #ToolWindow,
	#instVars : [
		'targetsTable',
		'pathView'
	]
}

{ #category : #actions }
TargetPickerWindow >> command: anId [
	| row name path |
	row := targetsTable selectedRow.
	name := (row between: 1 and: model targets size) ifTrue: [(model targets at: row) first] ifFalse: [nil].
	anId = 1 ifTrue: [name isNil ifFalse: [model connect: name]].
	anId = 2 ifTrue: [name isNil ifFalse: [model disconnect: name]].
	anId = 3 ifTrue: [model refresh].
	anId = 4 ifTrue: [
		path := (pathView text ifNil: ['']) trimmed.
		path isEmpty ifFalse: [model add: path name: path]].
	anId = 5 ifTrue: [name isNil ifFalse: [model pair: name]]
]

{ #category : #building }
TargetPickerWindow >> build [
	| toolbar |
	self makeWindow: 'Targets'.
	toolbar := Toolbar new.
	toolbar addItem: 1 title: 'Connect'; addItem: 2 title: 'Disconnect'; addItem: 3 title: 'Refresh'; addItem: 4 title: 'Add'; addItem: 5 title: 'Pair'.
	window toolbar: toolbar.
	toolbar action: [:id | self command: id].
	targetsTable := self table: #('Target' 'Socket' 'State') at: {0. 0. 560. 150}.
	targetsTable autoresize: 'width height'.
	targetsTable onDoubleClick: [:row | self command: 1].
	pathView := self textAt: {4. 156. 552. 24} editable: true.
	pathView autoresize: 'width top'.
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
