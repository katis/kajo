"The debugger's window (module 9c): a toolbar of the commands (proceed, restart, retry the send, step into, over, out, terminate, define the missing method), the stopped Process's frames, the selected frame's source with the range its pc is at highlighted, its variables and a workspace evaluating in the frame (Cmd-D, Cmd-P, Cmd-I). Cmd-S in the source saves the method and restarts the frame (fix and continue)."
Class {
	#name : #DebuggerWindow,
	#superclass : #ToolWindow,
	#instVars : [
		'framesTable',
		'sourceView',
		'variablesTable',
		'workspaceView'
	]
}

{ #category : #accessing }
DebuggerWindow >> sourceView [
	^ sourceView
]

{ #category : #actions }
DebuggerWindow >> command: anId [
	anId = 1 ifTrue: [^ model proceed].
	anId = 2 ifTrue: [^ model restart].
	anId = 3 ifTrue: [^ model retrySend].
	anId = 4 ifTrue: [^ model step: 'into'].
	anId = 5 ifTrue: [^ model step: 'over'].
	anId = 6 ifTrue: [^ model step: 'out'].
	anId = 7 ifTrue: [^ model terminate].
	anId = 8 ifTrue: [^ model defineMissingMethod]
]

{ #category : #building }
DebuggerWindow >> aspects [
	^ #(#status #frames #frame #state)
]

{ #category : #building }
DebuggerWindow >> build [
	| toolbar split |
	self makeWindow: model title.
	toolbar := Toolbar new.
	DebuggerWindow toolbarItems do: [:i | toolbar addItem: i first title: (i at: 2)].
	window toolbar: toolbar.
	toolbar action: [:id | self command: id].
	framesTable := self table: #('Frames') at: {0. 0. 900. 170}.
	framesTable autoresize: 'width'.
	framesTable onSelect: [:row | (row between: 1 and: model frames size) ifTrue: [model selectFrame: row]].
	sourceView := self textAt: {0. 172. 900. 250} editable: true.
	sourceView autoresize: 'width height'.
	self pane: sourceView keys: (DevTools keysOfPane: 'Debugger source') action: [:k |
		k = 'cmd-s' ifTrue: [model save: sourceView text] ifFalse: [self key: k in: sourceView with: nil]].
	split := window add: SplitView new.
	split x: 0 y: 424 width: 900 height: 190.
	split vertical: true.
	split autoresize: 'width top'.
	variablesTable := split add: TableView new.
	variablesTable x: 0 y: 0 width: 400 height: 190.
	variablesTable columns: #('Variable' 'Value').
	workspaceView := split add: TextView new.
	workspaceView x: 0 y: 0 width: 500 height: 190.
	workspaceView editable: true.
	self pane: workspaceView keys: (DevTools keysOfPane: 'Debugger evaluation pane')
		action: [:k | self key: k in: workspaceView with: model workspace].
	self addStatusLine
]

{ #category : #building }
DebuggerWindow >> defaultFrame [
	^ {90. 90. 900. 640}
]

{ #category : #updating }
DebuggerWindow >> showFrame [
	| src styles r |
	src := model source.
	sourceView text: src.
	styles := SourceColorer stylesFor: src.
	r := model range.
	(r notNil and: [r size = 2 and: [r first notNil]]) ifTrue: [
		styles := styles , {r first. r at: 2. 'background:highlight'}.
		sourceView selectFrom: r first to: r first - 1.
		sourceView scrollToOffset: r first].
	sourceView styles: styles.
	variablesTable rows: model variables.
	framesTable selectRow: (model frameIndex ifNil: [0])
]

{ #category : #updating }
DebuggerWindow >> update: anAspect [
	super update: anAspect.
	anAspect == #frames ifTrue: [^ framesTable list: model frameTitles].
	anAspect == #frame ifTrue: [^ self showFrame].
	anAspect == #state ifTrue: [^ window title: model title , ' [' , model state asString , ']']
]

{ #category : #updating }
DebuggerWindow >> workspaceView [
	^ workspaceView
]

{ #category : #building }
DebuggerWindow class >> toolbarItems [
	"The toolbar's commands: id, title."
	^ #(#(1 'Proceed') #(2 'Restart') #(3 'Retry send') #(4 'Into') #(5 'Over') #(6 'Out') #(7 'Terminate') #(8 'Define method'))
]
