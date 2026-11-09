"A workspace's window (module 9c): a text pane where Cmd-D evaluates the selection (or the line), Cmd-P prints its value after it, Cmd-I inspects it; a status line with the value's class. Since the discoverability follow-up the pane takes the Smalltalk menu's other items too (senders, implementors, browse, instances of it), lists them in its context menu, and the status line names the keys until the first evaluation."
Class {
	#name : #WorkspaceWindow,
	#superclass : #ToolWindow,
	#instVars : [
		'textView'
	]
}

{ #category : #accessing }
WorkspaceWindow >> textView [
	^ textView
]

{ #category : #building }
WorkspaceWindow >> build [
	self makeWindow: 'Workspace'.
	textView := self textAt: {0. 0. 600. 378} editable: true.
	textView autoresize: 'width height'.
	self pane: textView keys: (DevTools keysOfPane: 'Workspace') action: [:k | self key: k in: textView with: model].
	textView onChange: [:v | v styles: (SourceColorer stylesFor: (v text ifNil: ['']) pattern: false)].
	self addStatusLine.
	"Until the first evaluation the status line says how to evaluate (the discoverability follow-up)."
	model status isEmpty ifTrue: [model status: DevTools workspaceHint]
]

{ #category : #building }
WorkspaceWindow >> defaultFrame [
	^ {200. 200. 600. 400}
]
