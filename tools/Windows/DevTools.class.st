"The developer UI's entry (module 9c, docs/modules/developer-ui.md): the connected targets (DevClients by name), the open tool windows, the transcript of every target, the Tools menu in the menu bar. openLocal: is what the macOS shell runs in a development image: it connects to the image's own protocol socket (the local target: Kajo develops Kajo), opens the transcript, the target picker and a browser, and from then on a process.stopped event of any target opens a debugger on that Process (or brings its window back), a process.resumed one tells it. The project directory (2026-11-11): the tools keep no directory; the host holds each target's and writes the files of accepted changes there."
Class {
	#name : #DevTools,
	#superclass : #Object,
	#classInstVars : [
		'clients',
		'windows',
		'transcript',
		'menu',
		'debuggers',
		'targetsWatched',
		'smalltalkMenu',
		'helpMenu',
		'menusSupported'
	]
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
DevTools class >> connect: aTarget name: aName [
	"A client of aTarget (a socket path, an address, or a target's name: module 9d's phone), opening its session as the developer in package Tools when it is the local target (with the token the host holds); its stops open debuggers, its transcript joins the transcript's. The files of its changes go to the project directory the host holds for the target."
	| c |
	(self clientNamed: aName) ifNotNil: [:old | old isOpen ifTrue: [^ old]].
	c := DevClient connect: aTarget name: aName client: 'developer' package: (aName = 'local' ifTrue: ['Tools'] ifFalse: [nil]).
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
	aClient on: 'connection.open' do: [:e :c |
		c reconnects > 0 ifTrue: [self reconnected: c].
		self standingStops: e client: c].
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
DevTools class >> standingStops: anInfo client: aClient [
	"The development answers: session.open's answer lists the Processes that stood stopped when the session opened (an error before any client came, or while the link was down); each gets its debugger as a process.stopped event would open it."
	| stops |
	stops := [anInfo at: 'stopped'] on: Error do: [:e | nil].
	stops isNil ifTrue: [^ self].
	stops do: [:s | self stopped: s client: aClient]
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

{ #category : #it }
DevTools class >> browseIt: aString client: aClient [
	"Browse it: a class name (Foo, Foo class) selects the class in a browser, Foo>>bar the method; anything else is a selector whose implementors are listed."
	| w |
	aString isEmpty ifTrue: [^ nil].
	w := self browserFor: aClient.
	(aString includesSubstring: '>>') ifTrue: [^ w model selectMessage: aString].
	((aString byteAt: 1) between: 65 and: 90) ifTrue: [^ w model browseClass: aString].
	^ w model implementorsOf: aString
]

{ #category : #it }
DevTools class >> browserFor: aClient [
	"An open browser on aClient's target, or a new one."
	^ (self windowsOf: BrowserWindow) detect: [:w | w isOpen and: [w model client == aClient]] ifNone: [self browse: aClient]
]

{ #category : #it }
DevTools class >> implementorsOf: aSelector client: aClient [
	aSelector isEmpty ifTrue: [^ nil].
	^ (self browserFor: aClient) model implementorsOf: aSelector
]

{ #category : #it }
DevTools class >> inspect: aDescription client: aClient note: aString [
	"An inspector whose title carries aString (Instances of it: how many there were)."
	| m |
	(aDescription at: 'handle') isNil ifTrue: [^ nil].
	m := InspectorModel new client: aClient; yourself.
	m note: aString.
	m workspace inspectAction: [:d :c | self inspect: d client: c].
	(InspectorWindow on: m) open.
	m inspect: (aDescription at: 'handle').
	^ m view
]

{ #category : #it }
DevTools class >> instancesLimit [
	"How many instances Instances of it shows (allInstances:)."
	^ 1000
]

{ #category : #it }
DevTools class >> instancesOf: aSource with: aWorkspaceModel [
	"Instances of it: aSource evaluated once where aWorkspaceModel evaluates (a class, usually its name), then, about the object it answered (its handle), its instanceCount, then an inspector on its first instancesLimit instances whose title says how many there were. Evaluated once (the review fixes, part 2, item 9): a selection with a side effect runs it once, and the count and the list are of the same class."
	| limit |
	aSource isEmpty ifTrue: [^ aWorkspaceModel status: 'select a class to list its instances'].
	limit := self instancesLimit.
	aWorkspaceModel evaluate: aSource then: [:o | | w |
		w := self workspaceOn: o like: aWorkspaceModel.
		w evaluate: (self receiverSourceOf: o) , ' instanceCount' then: [:n | | count |
			count := (n at: 'value') asInteger.
			w evaluate: (self receiverSourceOf: o) , ' allInstances: ' , limit printString then: [:r |
				aWorkspaceModel status: aSource , ': ' , (n at: 'value') , ' instances'.
				self inspect: r client: aWorkspaceModel client
					note: ((count notNil and: [count > limit])
						ifTrue: [limit printString , ' of ' , count printString , ' instances']
						ifFalse: [(n at: 'value') , ' instances'])]]]
]

{ #category : #it }
DevTools class >> objects: aCount pointingTo: aName limit: aLimit [
	"The inspector's note and the status line of Objects pointing to it: how many there were (L of N when the limit cut the list) and what they point to."
	| n |
	n := aCount isNil ifTrue: ['?'] ifFalse: [aCount printString].
	^ ((aCount notNil and: [aCount > aLimit]) ifTrue: [aLimit printString , ' of ' , n] ifFalse: [n]) ,
		(aCount = 1 ifTrue: [' object'] ifFalse: [' objects']) , ' pointing to ' , aName
]

{ #category : #it }
DevTools class >> pointersTo: aSource with: aWorkspaceModel [
	"Objects pointing to it (the pointersTo: follow-up): aSource evaluated once where aWorkspaceModel evaluates, then, about the object it answered (its handle), its pointerCount, then an inspector on the first instancesLimit objects holding it (pointersTo:) whose title says how many there were and what they point to (the first evaluation's printString). Evaluated once (the review fixes, part 2, item 9): a selection with a side effect runs it once, and the count, the list and the title describe the same object. The session's handle table holds the object from that evaluation on, so it is among the holders, as it is for an inspected object."
	| limit |
	aSource isEmpty ifTrue: [^ aWorkspaceModel status: 'select an expression to find the objects pointing to it'].
	limit := self instancesLimit.
	aWorkspaceModel evaluate: aSource then: [:o | | w name |
		w := self workspaceOn: o like: aWorkspaceModel.
		name := self unquoted: (o at: 'value').
		name := name copyFrom: 1 to: (name byteSize min: 40).
		w evaluate: (self receiverSourceOf: o) , ' pointerCount' then: [:n | | count |
			count := (n at: 'value') asInteger.
			w evaluate: (self receiverSourceOf: o) , ' pointersTo: ' , limit printString then: [:r | | note |
				note := self objects: count pointingTo: name limit: limit.
				aWorkspaceModel status: note.
				self inspect: r client: aWorkspaceModel client note: note]]]
]

{ #category : #it }
DevTools class >> receiverSourceOf: aDescription [
	"What names an evaluation's answer in a later evaluation: self, the receiver being its handle; an answer with no handle (nil, a Boolean, a small Integer, a Character) by its printString, which evaluates to it."
	^ (aDescription at: 'handle') isNil ifTrue: ['(' , (aDescription at: 'value') , ')'] ifFalse: ['self']
]

{ #category : #it }
DevTools class >> sendersOf: aSelector client: aClient [
	aSelector isEmpty ifTrue: [^ nil].
	^ (self browserFor: aClient) model sendersOf: aSelector
]

{ #category : #it }
DevTools class >> unquoted: aString [
	"A String's printString as the String it prints ('it''s' is it's); anything else as it is."
	(aString byteSize >= 2 and: [(aString beginsWith: '''') and: [aString endsWith: '''']]) ifFalse: [^ aString].
	^ (aString copyFrom: 2 to: aString byteSize - 1) copyReplaceAll: '''''' with: ''''
]

{ #category : #it }
DevTools class >> workspaceOn: aDescription like: aWorkspaceModel [
	"A workspace model on aWorkspaceModel's client whose self is the object an evaluation answered (its handle)."
	| w |
	w := WorkspaceModel new client: aWorkspaceModel client; yourself.
	(aDescription at: 'handle') ifNotNil: [:h | w receiver: h].
	^ w
]

{ #category : #menus }
DevTools class >> contextMenuFor: someKeys action: aBlock [
	"A pane's context menu: the Smalltalk menu's items whose keys are among someKeys (the ones that apply to the pane; the rest are left out), in the menu's order, each giving its key to aBlock. nil on a host without menus (UIKit)."
	| items |
	self menusSupported ifFalse: [^ nil].
	items := self smalltalkItems select: [:i | someKeys includes: (i at: 3)].
	^ self menu: 'Smalltalk' items: items action: [:id | aBlock value: ((items detect: [:i | i first = id]) at: 3)]
]

{ #category : #menus }
DevTools class >> focusedPane [
	"The text pane of a tool window that is the first responder of the frontmost window, or nil: what a Smalltalk menu item acts on."
	self windows do: [:w | w textPanes do: [:p | p isFocused ifTrue: [^ p]]].
	^ nil
]

{ #category : #menus }
DevTools class >> glyphsOf: aKey [
	"A key's name ('cmd-shift-n') as the menus show it (⇧⌘N)."
	| parts s |
	parts := aKey splitOn: '-'.
	s := ''.
	(parts includes: 'ctrl') ifTrue: [s := s , '⌃'].
	(parts includes: 'alt') ifTrue: [s := s , '⌥'].
	(parts includes: 'shift') ifTrue: [s := s , '⇧'].
	(parts includes: 'cmd') ifTrue: [s := s , '⌘'].
	^ s , parts last asUppercase
]

{ #category : #menus }
DevTools class >> helpItem: anId [
	anId = 31 ifTrue: [^ self openShortcuts].
	anId = 32 ifTrue: [
		(View openURL: self homePage) ifFalse: [Transcript showLine: 'Help: cannot open ' , self homePage].
		^ self]
]

{ #category : #menus }
DevTools class >> helpItems [
	"The Help menu: id, title, key ('' for none)."
	^ #(#(31 'Keyboard Shortcuts' '') #(32 'Kajo on GitHub' ''))
]

{ #category : #menus }
DevTools class >> homePage [
	^ 'https://github.com/katis/kajo'
]

{ #category : #menus }
DevTools class >> keysOfPane: aName [
	"The Smalltalk menu's keys a text pane binds (paneKeys)."
	^ (self paneKeys detect: [:p | p first = aName]) at: 2
]

{ #category : #menus }
DevTools class >> menu: aTitle items: anArray action: aBlock [
	| m |
	m := Menu new.
	m title: aTitle.
	anArray do: [:i | m addItem: i first title: (i at: 2) key: ((i at: 3) isEmpty ifTrue: [nil] ifFalse: [i at: 3])].
	m action: aBlock.
	^ m
]

{ #category : #menus }
DevTools class >> menusSupported [
	^ menusSupported ifNil: [menusSupported := View supports: Menu kind]
]

{ #category : #menus }
DevTools class >> openShortcuts [
	"Help > Keyboard Shortcuts: a read-only window listing every binding of the tools (shortcutsText)."
	^ (ShortcutsWindow on: ToolModel new) open
]

{ #category : #menus }
DevTools class >> paneKeys [
	"Which of the Smalltalk menu's keys each kind of text pane binds: the items that apply to it (its context menu lists the same)."
	| evaluating |
	evaluating := #('cmd-d' 'cmd-p' 'cmd-i' 'cmd-shift-n' 'cmd-shift-m' 'cmd-shift-b' 'cmd-shift-i' 'cmd-shift-o').
	^ {{'Workspace'. evaluating}.
		{'Browser source'. #('cmd-s' 'cmd-shift-n' 'cmd-shift-m' 'cmd-shift-b')}.
		{'Inspector evaluation pane'. evaluating}.
		{'Debugger source'. #('cmd-s' 'cmd-shift-n' 'cmd-shift-m' 'cmd-shift-b')}.
		{'Debugger evaluation pane'. evaluating}}
]

{ #category : #menus }
DevTools class >> shortcutsText [
	"Every binding of the tools, made from the menus' item lists (toolsItems, smalltalkItems, helpItems), the panes' keys (paneKeys, which are Smalltalk items' keys) and the toolbars' commands, so the list cannot drift from what the tools do."
	| s line |
	s := WriteStream on: String new.
	line := [:glyphs :title | s tab; nextPutAll: glyphs; tab; nextPutAll: title; lf].
	s nextPutAll: 'Kajo: keyboard shortcuts'; lf; lf.
	s nextPutAll: 'Tools menu'; lf.
	self toolsItems do: [:i | line value: (self glyphsOf: (i at: 3)) value: (i at: 2)].
	s lf; nextPutAll: 'Smalltalk menu (on the focused text pane; the same items in its context menu)'; lf.
	self smalltalkItems do: [:i | line value: (self glyphsOf: (i at: 3)) value: (i at: 2)].
	s lf; nextPutAll: 'The Smalltalk items each text pane takes'; lf.
	self paneKeys do: [:p |
		s tab; nextPutAll: p first; nextPutAll: ': '.
		(p at: 2) do: [:k | s nextPutAll: (self glyphsOf: k); space; nextPutAll: ((self smalltalkItems detect: [:i | (i at: 3) = k]) at: 2)]
			separatedBy: [s nextPutAll: ', '].
		s lf].
	s lf; nextPutAll: 'Help menu'; lf.
	self helpItems do: [:i | line value: '' value: (i at: 2)].
	s lf; nextPutAll: 'Toolbars (buttons, no keys)'; lf.
	s tab; nextPutAll: 'Browser: '; nextPutAll: (self titlesOf: BrowserWindow toolbarItems); lf.
	s tab; nextPutAll: 'Debugger: '; nextPutAll: (self titlesOf: DebuggerWindow toolbarItems); lf.
	s lf; nextPutAll: 'Edit menu (the system''s): ⌘Z undo, ⇧⌘Z redo, ⌘X cut, ⌘C copy, ⌘V paste, ⌘A select all'; lf.
	^ s contents
]

{ #category : #menus }
DevTools class >> smalltalkItem: anId [
	"A Smalltalk menu item, chosen with the mouse or by a key the focused pane does not bind: the focused pane's own key action runs as if its key had been pressed, when the pane binds that key (an item that does not apply to the pane does nothing). A key the pane binds never reaches the menu: the text view takes it first."
	| item pane |
	item := self smalltalkItems detect: [:i | i first = anId] ifNone: [^ nil].
	pane := self focusedPane.
	pane isNil ifTrue: [^ nil].
	^ pane pressKey: (item at: 3)
]

{ #category : #menus }
DevTools class >> smalltalkItems [
	"The Smalltalk menu (the discoverability follow-up): id, title, key. Do it, Print it and Inspect it evaluate the selection or the line; Accept compiles the pane; Senders, Implementors and Browse act on the selection or the word at the insertion point, Instances of it on the class an evaluation of it answers, Objects pointing to it (the pointersTo: follow-up) on the object it answers. The shifted keys are free in the Tools, Edit and app menus."
	^ #(#(11 'Do it' 'cmd-d') #(12 'Print it' 'cmd-p') #(13 'Inspect it' 'cmd-i') #(14 'Accept' 'cmd-s')
		#(15 'Senders of it' 'cmd-shift-n') #(16 'Implementors of it' 'cmd-shift-m') #(17 'Browse it' 'cmd-shift-b')
		#(18 'Instances of it' 'cmd-shift-i') #(19 'Objects pointing to it' 'cmd-shift-o'))
]

{ #category : #menus }
DevTools class >> titlesOf: anArray [
	^ (anArray collect: [:i | i at: 2]) inject: '' into: [:a :t | a isEmpty ifTrue: [t] ifFalse: [a , ', ' , t]]
]

{ #category : #menus }
DevTools class >> toolsItems [
	"The Tools menu: id, title, key."
	^ #(#(1 'Browser' 'cmd-b') #(2 'Workspace' 'cmd-k') #(3 'Test Runner' 'cmd-u') #(4 'Transcript' 'cmd-j') #(5 'Targets' 'cmd-shift-t'))
]

{ #category : #menus }
DevTools class >> workspaceHint [
	"The status line of a new Workspace until its first evaluation: Do it, Print it and Inspect it with their keys, from the Smalltalk menu."
	^ ((self smalltalkItems first: 3) collect: [:i | (self glyphsOf: (i at: 3)) , ' ' , (i at: 2) asLowercase])
		inject: '' into: [:a :t | a isEmpty ifTrue: [t] ifFalse: [a , ' · ' , t]]
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
	"The Tools, Smalltalk and Help menus in the menu bar, with key equivalents, made from toolsItems, smalltalkItems and helpItems. Answers the Tools menu."
	menu isNil ifFalse: [^ menu].
	menu := self menu: 'Tools' items: self toolsItems action: [:id | self menuItem: id].
	menu installInMenuBar.
	smalltalkMenu := self menu: 'Smalltalk' items: self smalltalkItems action: [:id | self smalltalkItem: id].
	smalltalkMenu installInMenuBar.
	helpMenu := self menu: 'Help' items: self helpItems action: [:id | self helpItem: id].
	helpMenu installInMenuBar.
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
DevTools class >> openLocal: aSocketPath [
	"The shell's development mode: connect to this image's own protocol socket and open the tools. Answers the local client."
	| c |
	UIEventLoop start.
	c := self connect: aSocketPath name: 'local'.
	c isNil ifTrue: [^ nil].
	self installMenu.
	self openTranscript.
	self openTargets.
	self browse: c.
	^ c
]

{ #category : #opening }
DevTools class >> openTarget: aTarget name: aName [
	"Module 9d: the tools on another target (the phone, by its name or address), the changes they make written into the project directory the host holds for it. Answers the client."
	| c |
	UIEventLoop start.
	c := self connect: aTarget name: aName.
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
	m connectAction: [:name :path | self connect: path name: name].
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
	menu := nil.
	smalltalkMenu := nil.
	helpMenu := nil
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
