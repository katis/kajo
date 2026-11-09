"Module 9c's tests drive the developer UI in a test shell through these (module 9d: and the tools on another target over TCP, whose link drops): open the tools on the image's own socket, ask what the windows show, act as a user would (a browser compiling a method, a menu action that fails), and read what happened."
Class {
	#name : #ToolsProbe,
	#superclass : #Object,
	#classInstVars : [
		'results',
		'menu',
		'listed',
		'hierarchy',
		'framesBefore',
		'remoteProcess'
	]
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

{ #category : #remote }
ToolsProbe class >> openRemote: anAddress [
	"Module 9d: the tools on another target, by its address (the host holds its token)."
	^ (DevTools openTarget: anAddress name: 'remote' project: nil) notNil
]

{ #category : #remote }
ToolsProbe class >> remote [
	^ DevTools clientNamed: 'remote'
]

{ #category : #remote }
ToolsProbe class >> remoteReady [
	| c |
	c := self remote.
	^ c notNil and: [c isOpen and: [self browsers > 0 and: [self browser model hierarchy size > 100]]]
]

{ #category : #remote }
ToolsProbe class >> stopRemote [
	"A doit on the target stops at a missing method; a debugger opens."
	(WorkspaceModel new client: self remote; yourself) doIt: 'nil probeMissing'.
	^ true
]

{ #category : #remote }
ToolsProbe class >> remoteDebuggerReady [
	| d |
	DevTools debuggers isEmpty ifTrue: [^ false].
	d := DevTools debuggers last model.
	(d client == self remote and: [d state == #stopped and: [d frames notEmpty]]) ifFalse: [^ false].
	remoteProcess := d process.
	^ true
]

{ #category : #remote }
ToolsProbe class >> dropWithRequests [
	"The link drops (the test's host closes the sockets on this line), then two requests go out on the dead link: both are pending at the loss."
	| c |
	c := self remote.
	listed := nil.
	hierarchy := nil.
	framesBefore := (c latencies select: [:l | l first = 'process.frames']) size.
	Transcript show: 'probe: drop'; cr; flush.
	c processList: [:l | listed := l].
	c classHierarchy: [:h | hierarchy := h size].
	^ true
]

{ #category : #remote }
ToolsProbe class >> reconnected [
	"The client is open again on a new session, both requests were answered, the stopped Process is listed stopped, and its debugger fetched its frames again."
	| c d |
	c := self remote.
	(c isOpen and: [c reconnects > 0 and: [listed notNil and: [hierarchy notNil]]]) ifFalse: [^ false].
	(listed anySatisfy: [:p | (p at: 'process') = remoteProcess and: [(p at: 'stopped') notNil]]) ifFalse: [^ false].
	d := DevTools debuggers last model.
	^ d state == #stopped and: [(c latencies select: [:l | l first = 'process.frames']) size > framesBefore]
]

{ #category : #remote }
ToolsProbe class >> remoteRetried [
	^ self remote retried
]

{ #category : #remote }
ToolsProbe class >> remoteProcess [
	^ remoteProcess
]

{ #category : #remote }
ToolsProbe class >> remoteReconnects [
	^ self remote reconnects
]

{ #category : #remote }
ToolsProbe class >> pair: aTarget [
	"Module 9d: ask the host for aTarget's token in its own secure field; the token never comes here. Answers whether the host held one already."
	^ ClientTransport pair: aTarget
]

{ #category : #remote }
ToolsProbe class >> holdsTokenFor: anAddress [
	^ ClientTransport targets anySatisfy: [:t | (t at: 2) = anAddress and: [t at: 3]]
]

{ #category : #tags }
ToolsProbe class >> defineInTag: aTag [
	"Tags as subdirectories: accept a class definition into the local session's package (Tools) under aTag in the first browser, as a developer types it into the definition pane."
	| m |
	m := self browser model.
	m selectPackage: 'Tools'.
	m newClassTemplate.
	m accept: 'Object subclass: #ToolsTagProbe
	instanceVariableNames: ''a''
	classVariableNames: ''''
	package: #Tools
	tag: #' , aTag.
	^ true
]

{ #category : #tags }
ToolsProbe class >> definedInTag: aTag [
	"The browser has the define's reply for aTag: the class is in that tag and the files the target named (written by the client's transport before the reply reached the tools) include the tag's file."
	| c |
	c := Smalltalk at: #ToolsTagProbe ifAbsent: [^ false].
	(Smalltalk tagOf: c) = aTag asSymbol ifFalse: [^ false].
	^ self browser model filesWritten anySatisfy: [:f | (f at: 'path') = (aTag , '/ToolsTagProbe.class.st')]
]

{ #category : #tags }
ToolsProbe class >> removeTagProbe [
	| m |
	m := self browser model.
	m selectClass: 'ToolsTagProbe'.
	m removeClass.
	^ true
]

{ #category : #tags }
ToolsProbe class >> tagProbeRemoved [
	^ (Smalltalk includesKey: #ToolsTagProbe) not and: [self browser model status beginsWith: 'removed']
]
