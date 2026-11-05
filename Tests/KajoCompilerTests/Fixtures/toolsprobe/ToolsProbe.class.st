"Module 9c's tests drive the developer UI in a test shell through these: open the tools on the image's own socket, ask what the windows show, act as a user would (a browser compiling a method, a menu action that fails), and read what happened."
Class {
	#name : #ToolsProbe,
	#superclass : #Object,
	#classInstVars : [
		'results',
		'menu'
	],
	#category : #'Toolsprobe'
}

{ #category : #actions }
ToolsProbe >> brokenAction [
	"A browser action with a bug: missingStep is not defined yet."
	ToolsProbe note: self missingStep + 1
]

{ #category : #probing }
ToolsProbe class >> browser [
	^ (DevTools windowsOf: BrowserWindow) first
]

{ #category : #probing }
ToolsProbe class >> browsers [
	^ (DevTools windowsOf: BrowserWindow) size
]

{ #category : #probing }
ToolsProbe class >> compileThroughTheBrowser [
	"Select this class in the first browser and accept a new method in its source pane."
	| m |
	m := self browser model.
	m selectClass: 'ToolsProbe'.
	m newMethodTemplate.
	m accept: 'probeAnswer
	^ 42'.
	^ true
]

{ #category : #probing }
ToolsProbe class >> debuggerReady [
	"A debugger is open on a doesNotUnderstand: stop with its frames."
	| d |
	DevTools debuggers isEmpty ifTrue: [^ false].
	d := DevTools debuggers last model.
	^ d frames notEmpty and: [d isDoesNotUnderstand]
]

{ #category : #probing }
ToolsProbe class >> defineTheMissingMethod [
	"In the debugger: define the method (a browser opens on the class with a template): true, or what went otherwise."
	| before b d |
	before := self browsers.
	d := DevTools debuggers last model.
	d defineMissingMethod.
	self browsers > before ifFalse: [^ 'no browser opened: ' , d status , ' ' , self state].
	b := (DevTools windowsOf: BrowserWindow) last model.
	^ b sourceKind == #newMethod ifTrue: [true] ifFalse: [b sourceKind printString , ' ' , b className printString , ' ' , self state]
]

{ #category : #probing }
ToolsProbe class >> acceptTheFix [
	(DevTools windowsOf: BrowserWindow) last model accept: 'missingStep
	^ 41'.
	^ true
]

{ #category : #probing }
ToolsProbe class >> handOvers [
	^ UIEventLoop handOverCount
]

{ #category : #probing }
ToolsProbe class >> hasProbeAnswer [
	^ (ToolsProbe includesSelector: #probeAnswer) and: [ToolsProbe new probeAnswer = 42]
]

{ #category : #probing }
ToolsProbe class >> installMenu [
	"A context menu on the first browser's source pane: item 1 runs the broken action, item 2 notes #again. Answers the menu's handle."
	menu := Menu new.
	menu addItem: 1 title: 'Broken' key: nil; addItem: 2 title: 'Again' key: nil.
	menu action: [:id |
		id = 1 ifTrue: [ToolsProbe new brokenAction].
		id = 2 ifTrue: [ToolsProbe note: #again]].
	self browser sourceView contextMenu: menu.
	^ menu handle
]

{ #category : #probing }
ToolsProbe class >> latencyCount [
	^ DevTools local latencies size
]

{ #category : #probing }
ToolsProbe class >> loopProcessId [
	^ UIEventLoop process id
]

{ #category : #probing }
ToolsProbe class >> note: anObject [
	results isNil ifTrue: [results := OrderedCollection new].
	results add: anObject
]

{ #category : #probing }
ToolsProbe class >> open: aSocketPath project: aDirectory [
	^ (DevTools openLocal: aSocketPath project: aDirectory) notNil
]

{ #category : #probing }
ToolsProbe class >> ready [
	"The local client's session is open and the first browser has the class tree."
	| c |
	c := DevTools local.
	(c notNil and: [c isOpen]) ifFalse: [^ false].
	self browsers = 0 ifTrue: [^ false].
	^ self browser model hierarchy size > 100
]

{ #category : #probing }
ToolsProbe class >> state [
	"What the tools are doing, for a test's failure message."
	| c |
	c := DevTools local.
	^ String streamContents: [:s |
		s nextPutAll: 'client '; print: (c ifNotNil: [:x | x state]); nextPutAll: ' lost '; print: (c ifNotNil: [:x | x lostReason]);
			nextPutAll: ' pending '; print: (c ifNotNil: [:x | x pendingCount]);
			nextPutAll: ' browsers '; print: self browsers;
			nextPutAll: ' hierarchy '; print: (self browsers = 0 ifTrue: [0] ifFalse: [self browser model hierarchy size]);
			nextPutAll: ' status '; print: (self browsers = 0 ifTrue: [''] ifFalse: [self browser model status]);
			nextPutAll: ' loop errors '; print: UIEventLoop errorCount;
			nextPutAll: ' transcript '; print: (DevTools transcript lines last: (DevTools transcript lines size min: 3))]
]

{ #category : #probing }
ToolsProbe class >> results [
	^ (results ifNil: [#()]) asArray printString
]

{ #category : #probing }
ToolsProbe class >> transcriptHas: aString [
	^ DevTools transcript lines anySatisfy: [:l | l includesSubstring: aString]
]

{ #category : #probing }
ToolsProbe class >> compiledThroughTheBrowser [
	"The browser has the compile's reply: the method is in the image and its file was written before the reply reached the tools (the client's transport writes the files first)."
	^ self hasProbeAnswer and: [self browser model status beginsWith: 'compiled']
]
