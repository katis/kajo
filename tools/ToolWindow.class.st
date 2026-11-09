"A tool's window (module 9c): native views over the wrappers, built in build, refreshed from the model in update:, the model's actions bound to the views' events. Frames are in points; a window opens where the last one of its kind was closed (the frames are kept here, on the Smalltalk side) or at its default. Closing it tells the model (handles released) and DevTools."
Class {
	#name : #ToolWindow,
	#superclass : #Object,
	#instVars : [
		'model',
		'window',
		'statusLabel',
		'panes'
	],
	#classInstVars : [
		'savedFrames'
	],
	#category : #'Tools-Windows'
}

{ #category : #accessing }
ToolWindow >> model [
	^ model
]

{ #category : #accessing }
ToolWindow >> textPanes [
	"The text panes the Smalltalk menu can act on (pane:keys:action:)."
	^ panes ifNil: [#()]
]

{ #category : #accessing }
ToolWindow >> window [
	^ window
]

{ #category : #building }
ToolWindow >> addStatusLine [
	| f |
	f := self defaultFrame.
	statusLabel := window add: Label new.
	statusLabel x: 8 y: (f at: 4) - 22 width: (f at: 3) - 16 height: 20.
	statusLabel autoresize: 'width top'.
	^ statusLabel
]

{ #category : #building }
ToolWindow >> aspects [
	"What the window shows of a model that already has it when the window opens."
	^ #(#status)
]

{ #category : #building }
ToolWindow >> build [
	"Make the window's views (subclasses)."
	^ self subclassResponsibility
]

{ #category : #building }
ToolWindow >> defaultFrame [
	^ {120. 80. 700. 500}
]

{ #category : #building }
ToolWindow >> frameName [
	^ self class name
]

{ #category : #building }
ToolWindow >> makeWindow: aTitle [
	| f |
	f := self defaultFrame.
	window := Window new.
	window title: aTitle.
	window x: f first y: (f at: 2) width: (f at: 3) height: (f at: 4).
	window onClose: [:w | self closed].
	^ window
]

{ #category : #building }
ToolWindow >> pane: aTextView keys: someKeys action: aBlock [
	"aTextView is a text pane of this window (the discoverability follow-up): it binds someKeys (Smalltalk menu keys, DevTools paneKeys), reports them to aBlock, and gets a context menu of the same items, which runs aBlock exactly as the key does. The Smalltalk menu finds it when it is focused (textPanes)."
	aTextView bindKeys: someKeys.
	aTextView onKey: aBlock.
	(DevTools contextMenuFor: someKeys action: [:k | aTextView pressKey: k]) ifNotNil: [:m | aTextView contextMenu: m].
	panes isNil ifTrue: [panes := OrderedCollection new].
	panes add: aTextView.
	^ aTextView
]

{ #category : #building }
ToolWindow >> table: anArray at: aFrame [
	"A table with columns anArray at {x. y. width. height}."
	| t |
	t := window add: TableView new.
	t x: aFrame first y: (aFrame at: 2) width: (aFrame at: 3) height: (aFrame at: 4).
	t columns: anArray.
	^ t
]

{ #category : #building }
ToolWindow >> textAt: aFrame editable: aBoolean [
	| t |
	t := window add: TextView new.
	t x: aFrame first y: (aFrame at: 2) width: (aFrame at: 3) height: (aFrame at: 4).
	t editable: aBoolean.
	^ t
]

{ #category : #it }
ToolWindow >> isWordByte: aByte [
	"A byte of an identifier or a keyword: a letter, a digit, a colon, an underscore."
	^ (aByte between: 48 and: 58) or: [(aByte between: 65 and: 90) or: [(aByte between: 97 and: 122) or: [aByte = 95]]]
]

{ #category : #it }
ToolWindow >> itIn: aTextView [
	"What an item on 'it' acts on: the selection, trimmed, or else the word the insertion point is in or after."
	| text sel start stop |
	text := aTextView text ifNil: [''].
	sel := aTextView selection.
	(sel at: 2) >= sel first ifTrue: [^ (text copyFrom: sel first to: (sel at: 2)) trimmed].
	start := sel first min: text byteSize + 1.
	stop := start - 1.
	[start > 1 and: [self isWordByte: (text byteAt: start - 1)]] whileTrue: [start := start - 1].
	[stop < text byteSize and: [self isWordByte: (text byteAt: stop + 1)]] whileTrue: [stop := stop + 1].
	^ stop < start ifTrue: [''] ifFalse: [text copyFrom: start to: stop]
]

{ #category : #it }
ToolWindow >> key: aKey in: aTextView with: aWorkspaceModelOrNil [
	"The Smalltalk menu's items on a text pane: Do it, Print it, Inspect it, Instances of it and Objects pointing to it evaluate through aWorkspaceModelOrNil (the pane's evaluation context), Senders, Implementors and Browse open a browser on the target. Accept is each window's own."
	(#('cmd-d' 'cmd-p' 'cmd-i') includes: aKey) ifTrue: [
		^ aWorkspaceModelOrNil ifNotNil: [:w | self evaluateIn: aTextView with: w key: aKey]].
	aKey = 'cmd-shift-n' ifTrue: [^ DevTools sendersOf: (self selectorIn: aTextView) client: model client].
	aKey = 'cmd-shift-m' ifTrue: [^ DevTools implementorsOf: (self selectorIn: aTextView) client: model client].
	aKey = 'cmd-shift-b' ifTrue: [^ DevTools browseIt: (self itIn: aTextView) client: model client].
	aKey = 'cmd-shift-i' ifTrue: [^ aWorkspaceModelOrNil ifNotNil: [:w | DevTools instancesOf: (self itIn: aTextView) with: w]].
	aKey = 'cmd-shift-o' ifTrue: [^ aWorkspaceModelOrNil ifNotNil: [:w | DevTools pointersTo: (self itIn: aTextView) with: w]]
]

{ #category : #it }
ToolWindow >> selectorIn: aTextView [
	"The selector it names: a keyword message's keywords joined (at: 1 put: 2 is at:put:), else its first word (a #symbol's without the #)."
	| it words keywords |
	it := self itIn: aTextView.
	(it beginsWith: '#') ifTrue: [it := it allButFirst].
	words := it substrings.
	keywords := words select: [:w | (w endsWith: ':') and: [w byteSize > 1]].
	keywords isEmpty ifFalse: [^ keywords inject: '' into: [:a :w | a , w]].
	^ words isEmpty ifTrue: [''] ifFalse: [words first]
]

{ #category : #opening }
ToolWindow >> close [
	window isNil ifFalse: [window close].
	self closed
]

{ #category : #opening }
ToolWindow >> closed [
	window isNil ifTrue: [^ self].
	(window handle notNil and: [window handle > 0]) ifTrue: [
		[ToolWindow saveFrame: window frame of: self frameName] on: Error do: [:e | nil]].
	model closed.
	DevTools forgetWindow: self.
	window := nil
]

{ #category : #opening }
ToolWindow >> isOpen [
	^ window notNil
]

{ #category : #opening }
ToolWindow >> open [
	self build.
	(ToolWindow savedFrameOf: self frameName) ifNotNil: [:f |
		(f allSatisfy: [:n | n isNumber]) ifTrue: [window x: f first y: (f at: 2) width: (f at: 3) height: (f at: 4)]].
	model view: self.
	self aspects do: [:a | self update: a].
	window show.
	DevTools noteWindow: self.
	^ self
]

{ #category : #opening }
ToolWindow >> setModel: aToolModel [
	model := aToolModel
]

{ #category : #updating }
ToolWindow >> evaluateIn: aTextView with: aWorkspaceModel key: aKey [
	"Cmd-D, Cmd-P, Cmd-I in a text view: the selection, or the line the insertion point is on."
	| text sel start stop src |
	text := aTextView text ifNil: [''].
	sel := aTextView selection.
	start := sel first.
	stop := sel at: 2.
	stop < start ifTrue: [ | lc |
		lc := TextView lineAndColumnOf: start in: text.
		start := TextView offsetOfLine: lc first column: 1 in: text.
		stop := start.
		[stop <= text byteSize and: [(text byteAt: stop) ~= 10]] whileTrue: [stop := stop + 1].
		stop := stop - 1].
	src := stop < start ifTrue: [''] ifFalse: [text copyFrom: start to: stop].
	aKey = 'cmd-d' ifTrue: [^ aWorkspaceModel doIt: src].
	aKey = 'cmd-i' ifTrue: [^ aWorkspaceModel inspectIt: src].
	aKey = 'cmd-p' ifTrue: [
		^ aWorkspaceModel evaluate: src then: [:r | | v t |
			v := ' ' , (r at: 'value').
			t := aTextView text ifNil: [''].
			aTextView text: (t copyFrom: 1 to: stop) , v , (t copyFrom: stop + 1 to: t byteSize).
			aTextView selectFrom: stop + 1 to: stop + v byteSize.
			aWorkspaceModel status: (r at: 'class')]]
]

{ #category : #updating }
ToolWindow >> update: anAspect [
	anAspect == #status ifTrue: [statusLabel isNil ifFalse: [statusLabel text: model status]]
]

{ #category : #frames }
ToolWindow class >> saveFrame: anArray of: aName [
	savedFrames isNil ifTrue: [savedFrames := Dictionary new].
	savedFrames at: aName put: anArray
]

{ #category : #frames }
ToolWindow class >> savedFrameOf: aName [
	self == ToolWindow ifFalse: [^ ToolWindow savedFrameOf: aName].
	savedFrames isNil ifTrue: [^ nil].
	^ savedFrames at: aName ifAbsent: [nil]
]

{ #category : #'instance creation' }
ToolWindow class >> on: aToolModel [
	^ self new setModel: aToolModel
]
