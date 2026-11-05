"The developer UI's entry (module 9c, docs/modules/developer-ui.md): the connected targets (DevClients by name), the open tool windows, the transcript of every target, the Tools menu in the menu bar. openLocal:project: is what the macOS shell runs in a development image: it connects to the image's own protocol socket (the local target: Kajo develops Kajo), opens the transcript, the target picker and a browser, and from then on a process.stopped event of any target opens a debugger on that Process (or brings its window back), a process.resumed one tells it."
Class {
	#name : #DevTools,
	#superclass : #Object,
	#classInstVars : [
		'clients',
		'windows',
		'transcript',
		'project',
		'menu',
		'debuggers',
		'targetsWatched'
	],
	#category : #'Tools-Windows'
}

{ #category : #clients }
DevTools class >> clientNamed: aName [
	clients isNil ifTrue: [^ nil].
	^ clients at: aName ifAbsent: [nil]
]

{ #category : #clients }
DevTools class >> clients [
	^ clients ifNil: [#()] ifNotNil: [:c | c values]
]

{ #category : #clients }
DevTools class >> connect: aPath name: aName token: aTokenOrNil [
	"A client of a target, opening its session as the developer in package Tools when it is the local target; its stops open debuggers, its transcript joins the transcript's."
	^ self connect: aPath name: aName token: aTokenOrNil project: (aName = 'local' ifTrue: [project] ifFalse: [nil])
]

{ #category : #clients }
DevTools class >> connect: aTarget name: aName token: aTokenOrNil project: aDirectoryOrNil [
	"A client of aTarget (a socket path, an address, or a target's name: module 9d's phone), the changes it makes written into aDirectoryOrNil."
	| c |
	(self clientNamed: aName) ifNotNil: [:old | old isOpen ifTrue: [^ old]].
	c := DevClient connect: aTarget name: aName client: 'developer' package: (aName = 'local' ifTrue: ['Tools'] ifFalse: [nil])
		token: aTokenOrNil project: aDirectoryOrNil.
	c isNil ifTrue: [^ nil].
	self register: c.
	^ c
]

{ #category : #clients }
DevTools class >> local [
	^ self clientNamed: 'local'
]

{ #category : #clients }
DevTools class >> register: aClient [
	"aClient's events reach the tools: stops open debuggers, transcript lines the transcript."
	clients isNil ifTrue: [clients := Dictionary new].
	clients at: aClient name put: aClient.
	aClient on: 'process.stopped' do: [:e :c | self stopped: e client: c].
	aClient on: 'process.resumed' do: [:e :c | self resumed: e client: c].
	aClient on: 'connection.open' do: [:e :c | c reconnects > 0 ifTrue: [self reconnected: c]].
	self transcript listenTo: aClient
]

{ #category : #debugging }
DevTools class >> debuggerFor: aProcessId client: aClient [
	debuggers isNil ifTrue: [^ nil].
	^ debuggers detect: [:w | w isOpen and: [w model client == aClient and: [w model process = aProcessId]]] ifNone: [nil]
]

{ #category : #debugging }
DevTools class >> debuggers [
	^ debuggers ifNil: [#()]
]

{ #category : #debugging }
DevTools class >> reconnected: aClient [
	"Module 9d: after a dropped link the stopped Processes are still stopped in the target: each debugger of aClient asks for its frames again, or says its Process went on or is gone (process.list)."
	aClient processList: [:list |
		self debuggers do: [:w |
			(w isOpen and: [w model client == aClient]) ifTrue: [ | p |
				p := list detect: [:e | (e at: 'process') = w model process] ifNone: [nil].
				(p notNil and: [(p at: 'stopped') notNil])
					ifTrue: [w model refresh]
					ifFalse: [w model resumed]]]]
]

{ #category : #debugging }
DevTools class >> resumed: anEvent client: aClient [
	(self debuggerFor: (anEvent at: 'process') client: aClient) ifNotNil: [:w | w model resumed]
]

{ #category : #debugging }
DevTools class >> stopped: anEvent client: aClient [
	"A Process stopped in a target: its debugger, opened or brought back."
	| w m |
	w := self debuggerFor: (anEvent at: 'process') client: aClient.
	w isNil ifFalse: [w window show. ^ w model stopped: anEvent].
	m := DebuggerModel new client: aClient; yourself.
	m browseAction: [:cls :sel :then | (self browse: aClient) model defineMethod: sel in: cls then: then].
	m stopped: anEvent.
	w := (DebuggerWindow on: m) open.
	debuggers isNil ifTrue: [debuggers := OrderedCollection new].
	debuggers := (debuggers select: [:d | d isOpen]) asOrderedCollection.
	debuggers add: w.
	^ w
]

{ #category : #opening }
DevTools class >> browse: aClient [
	| m |
	m := BrowserModel new client: aClient; yourself.
	(BrowserWindow on: m) open.
	m refresh.
	^ m view
]

{ #category : #opening }
DevTools class >> inspect: aDescription client: aClient [
	| m |
	(aDescription at: 'handle') isNil ifTrue: [^ nil].
	m := InspectorModel new client: aClient; yourself.
	m workspace inspectAction: [:d :c | self inspect: d client: c].
	(InspectorWindow on: m) open.
	m inspect: (aDescription at: 'handle').
	^ m view
]

{ #category : #opening }
DevTools class >> installMenu [
	"The Tools menu in the menu bar, with key equivalents."
	menu isNil ifFalse: [^ menu].
	menu := Menu new.
	menu title: 'Tools'.
	menu addItem: 1 title: 'Browser' key: 'cmd-b'; addItem: 2 title: 'Workspace' key: 'cmd-k';
		addItem: 3 title: 'Test Runner' key: 'cmd-u'; addItem: 4 title: 'Transcript' key: 'cmd-j'; addItem: 5 title: 'Targets' key: 'cmd-shift-t'.
	menu action: [:id | self menuItem: id].
	menu installInMenuBar.
	^ menu
]

{ #category : #opening }
DevTools class >> menuItem: anId [
	| c |
	c := self local ifNil: [self clients isEmpty ifTrue: [nil] ifFalse: [self clients first]].
	anId = 1 ifTrue: [^ self browse: c].
	anId = 2 ifTrue: [^ self openWorkspace: c].
	anId = 3 ifTrue: [^ self openTestRunner: c].
	anId = 4 ifTrue: [^ self openTranscript].
	anId = 5 ifTrue: [^ self openTargets]
]

{ #category : #opening }
DevTools class >> openLocal: aSocketPath project: aDirectoryOrNil [
	"The shell's development mode: connect to this image's own protocol socket and open the tools. Answers the local client."
	| c |
	project := aDirectoryOrNil.
	UIEventLoop start.
	c := self connect: aSocketPath name: 'local' token: nil.
	c isNil ifTrue: [^ nil].
	self installMenu.
	self openTranscript.
	self openTargets.
	self browse: c.
	^ c
]

{ #category : #opening }
DevTools class >> openTarget: aTarget name: aName project: aDirectoryOrNil [
	"Module 9d: the tools on another target (the phone, by its name or address), the changes they make written into aDirectoryOrNil. Answers the client."
	| c |
	project := aDirectoryOrNil.
	UIEventLoop start.
	c := self connect: aTarget name: aName token: nil project: aDirectoryOrNil.
	c isNil ifTrue: [^ nil].
	self installMenu.
	self openTranscript.
	self openTargets.
	self browse: c.
	^ c
]

{ #category : #opening }
DevTools class >> openTargets [
	| m |
	m := TargetPickerModel new.
	m connectAction: [:name :path :token | self connect: path name: name token: token].
	(TargetPickerWindow on: m) open.
	m refresh.
	targetsWatched == true ifFalse: [
		targetsWatched := true.
		DevClient onTargetsChanged: [(self windowsOf: TargetPickerWindow) do: [:w | w model refresh]]].
	^ m view
]

{ #category : #opening }
DevTools class >> openTestRunner: aClient [
	| m |
	m := TestRunnerModel new client: aClient; yourself.
	(TestRunnerWindow on: m) open.
	m loadClasses.
	^ m view
]

{ #category : #opening }
DevTools class >> openTranscript [
	^ (TranscriptWindow on: self transcript) open
]

{ #category : #opening }
DevTools class >> openWorkspace: aClient [
	| m |
	m := WorkspaceModel new client: aClient; yourself.
	m inspectAction: [:d :c | self inspect: d client: c].
	^ (WorkspaceWindow on: m) open
]

{ #category : #windows }
DevTools class >> forgetWindow: aToolWindow [
	windows isNil ifFalse: [windows remove: aToolWindow ifAbsent: [nil]]
]

{ #category : #windows }
DevTools class >> noteWindow: aToolWindow [
	windows isNil ifTrue: [windows := OrderedCollection new].
	windows add: aToolWindow
]

{ #category : #windows }
DevTools class >> reset [
	"Close every window and connection (tests)."
	self windows copy do: [:w | w close].
	self clients do: [:c | c close].
	clients := nil.
	windows := nil.
	debuggers := nil.
	transcript := nil.
	menu := nil
]

{ #category : #windows }
DevTools class >> transcript [
	transcript isNil ifTrue: [transcript := TranscriptModel new].
	^ transcript
]

{ #category : #windows }
DevTools class >> windows [
	^ windows ifNil: [#()]
]

{ #category : #windows }
DevTools class >> windowsOf: aClass [
	^ (self windows select: [:w | w isKindOf: aClass]) asArray
]
