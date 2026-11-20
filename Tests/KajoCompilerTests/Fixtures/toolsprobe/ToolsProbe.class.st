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
		'remoteProcess',
		'typesEvents',
		'typesMark'
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
ToolsProbe class >> compileTypedThroughTheBrowser [
	"Types 1: accept a method with types in its pattern in the first browser's source pane."
	| m |
	m := self browser model.
	m selectClass: 'ToolsProbe'.
	m newMethodTemplate.
	m accept: 'probeTyped: x <Integer> ^<Integer>
	^ x + 1'.
	^ true
]

{ #category : #probing }
ToolsProbe class >> compiledTypedThroughTheBrowser [
	"Types 1: the typed method runs, its recorded source keeps its types, and the browser shows them."
	^ (ToolsProbe includesSelector: #probeTyped:)
		and: [(ToolsProbe new probeTyped: 41) = 42
		and: [((Smalltalk sourceOf: (ToolsProbe compiledMethodAt: #probeTyped:)) beginsWith: 'probeTyped: x <Integer> ^<Integer>')
		and: [(self browser model status beginsWith: 'compiled')
		and: [self browser model source includesSubstring: 'probeTyped: x <Integer> ^<Integer>']]]]
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
	^ DevTools local replyCount
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
ToolsProbe class >> open: aSocketPath [
	"The tools on the local target; the test sets its project directory in the host first (the image names none)."
	^ (DevTools openLocal: aSocketPath) notNil
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
	^ (DevTools openTarget: anAddress name: 'remote') notNil
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
	framesBefore := (c repliesOf: 'process.frames').
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
	^ d state == #stopped and: [(c repliesOf: 'process.frames') > framesBefore]
]

{ #category : #remote }
ToolsProbe class >> remoteState [
	"The remote client for a failure message: its state, why it was lost, pending requests, reconnects, requests sent again, its outages ({microseconds from the loss to the new session. requests sent again}), whether the two requests of dropWithRequests were answered, and the tools' last transcript lines (where a failed request's error goes)."
	| c |
	c := self remote.
	^ String streamContents: [:s |
		s nextPutAll: 'remote '; print: (c ifNotNil: [:x | x state]); nextPutAll: ' lost '; print: (c ifNotNil: [:x | x lostReason]);
			nextPutAll: ' pending '; print: (c ifNotNil: [:x | x pendingCount]);
			nextPutAll: ' reconnects '; print: (c ifNotNil: [:x | x reconnects]);
			nextPutAll: ' retried '; print: (c ifNotNil: [:x | x retried]);
			nextPutAll: ' outages '; print: (c ifNotNil: [:x | x outages asArray]);
			nextPutAll: ' listed '; print: listed notNil; nextPutAll: ' hierarchy '; print: hierarchy notNil;
			nextPutAll: ' transcript '; print: (DevTools transcript lines last: (DevTools transcript lines size min: 6))]
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

{ #category : #project }
ToolsProbe class >> projectOf: aTarget [
	"The project directory: what the host answers for aTarget (a String or nil)."
	^ ClientTransport projectOf: aTarget
]

{ #category : #project }
ToolsProbe class >> chooseProject: aTarget [
	"The project directory: the picker's Project… on aTarget (the host's panel asks)."
	| m |
	m := TargetPickerModel new.
	m chooseProject: aTarget.
	^ m status
]

{ #category : #project }
ToolsProbe class >> pickerShows: aDirectory for: aTarget [
	"The target picker lists aTarget with aDirectory as its project directory."
	| m |
	m := TargetPickerModel new.
	m refresh.
	^ m rows anySatisfy: [:r | r first = aTarget and: [(r at: 4) = aDirectory]]
]

{ #category : #project }
ToolsProbe class >> connect: aPath naming: aDirectory [
	"Primitive 164's connect with a fourth argument, a directory the image names: the host refuses it (nil)."
	^ (ClientTransport primCall: 'connect' handle: nil with: {aPath. 'developer'. nil. aDirectory}) isNil
]

{ #category : #types }
ToolsProbe class >> startTypesWithoutTheWholeCheck [
	"Types 3: the type checker started before the tools ask, without its first check of the whole image (TypeService startCheckingAll: false, as Types 2's live tests start it): the whole check took 1116 s of a request under ThreadSanitizer, and the first request's time is measured apart (docs/modules/types-3.md). What changes from here on is checked, so the class this test defines is."
	TypeService startCheckingAll: false.
	^ true
]

{ #category : #types }
ToolsProbe class >> defineTypesProbe [
	"Types 3: through the first browser, a class (its definition accepted) and then, once it is there, a method with a known diagnostic (it answers an Integer where String is declared)."
	| m |
	typesEvents := 0.
	DevTools local on: 'diagnostics.changed' do: [:e | ((e at: 'methods') includes: 'ToolsTypesProbe>>answer') ifTrue: [typesEvents := typesEvents + 1]].
	m := self browser model.
	m selectPackage: 'Tools'.
	m newClassTemplate.
	m accept: 'Object subclass: #ToolsTypesProbe
	instanceVariableNames: ''''
	classVariableNames: ''''
	package: #Tools'.
	^ true
]

{ #category : #types }
ToolsProbe class >> typesProbeDefined [
	^ (Smalltalk includesKey: #ToolsTypesProbe) and: [self browser model className = 'ToolsTypesProbe']
]

{ #category : #types }
ToolsProbe class >> compileTypesProbe: aSource [
	| m |
	m := self browser model.
	m selectClass: 'ToolsTypesProbe'.
	m newMethodTemplate.
	m accept: aSource.
	^ true
]

{ #category : #types }
ToolsProbe class >> typesProbeShows: aCount [
	"The first browser shows ToolsTypesProbe>>answer as installed (marks shown) holding aCount diagnostics, and when it holds one, its kind, its mark in the source and the status line's text."
	| m d |
	m := self browser model.
	(m className = 'ToolsTypesProbe' and: [m selector = 'answer' and: [m marks == #shown]]) ifFalse: [^ false].
	m diagnostics size = aCount ifFalse: [^ false].
	aCount = 0 ifTrue: [^ (m diagnosedSelectors includes: 'answer') not].
	d := m diagnostics first.
	^ (d at: 'kind') = 'returnType'
		and: [(m diagnosedSelectors includes: 'answer')
		and: [(m status beginsWith: '1 type diagnostic: ')
		and: [(self browser diagnosticStylesIn: m source) includes: BrowserWindow diagnosticStyle]]]
]

{ #category : #types }
ToolsProbe class >> typesEvents [
	"diagnostics.changed events the local client got that named ToolsTypesProbe>>answer."
	^ typesEvents ifNil: [0]
]

{ #category : #types }
ToolsProbe class >> typesState [
	"What the browser holds of the probe, for a failure message."
	| m |
	m := self browser model.
	^ String streamContents: [:s |
		s nextPutAll: 'class '; print: m className; nextPutAll: ' selector '; print: m selector; nextPutAll: ' marks '; print: m marks;
			nextPutAll: ' diagnostics '; print: (m diagnostics collect: [:d | d at: 'text']) asArray;
			nextPutAll: ' failure '; print: m diagnosticsFailure; nextPutAll: ' events '; print: self typesEvents;
			nextPutAll: ' status '; print: m status; nextPutAll: ' '; nextPutAll: self state]
]

{ #category : #types }
ToolsProbe class >> markTypesEvents [
	"The events counted so far; typesEventCame answers whether one more came."
	typesMark := self typesEvents.
	^ true
]

{ #category : #types }
ToolsProbe class >> typesEventCame [
	^ self typesEvents > (typesMark ifNil: [0])
]
