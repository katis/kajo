"A workspace's window (module 9c): a text pane where Cmd-D evaluates the selection (or the line), Cmd-P prints its value after it, Cmd-I inspects it; a status line with the value's class."
Class {
	#name : #WorkspaceWindow,
	#superclass : #ToolWindow,
	#instVars : [
		'textView'
	],
	#category : #'Tools-Windows'
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
	textView bindKeys: #('cmd-d' 'cmd-p' 'cmd-i').
	textView onKey: [:k | self evaluateIn: textView with: model key: k].
	textView onChange: [:v | v styles: (SourceColorer stylesFor: (v text ifNil: ['']) pattern: false)].
	self addStatusLine
]

{ #category : #building }
WorkspaceWindow >> defaultFrame [
	^ {200. 200. 600. 400}
]
