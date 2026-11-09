"The discoverability follow-up's tools, headless against fake targets: every key a tool's text pane binds is a Smalltalk menu item's and is listed by Help > Keyboard Shortcuts (made from the menus); a Smalltalk menu item runs the focused pane's own key action once and does nothing on a pane it does not apply to; each pane's context menu lists the items that apply; a new Workspace names its keys until the first evaluation; a browser names Accept's key once a method is edited; Instances of it opens an inspector whose title says how many instances there were, and Objects pointing to it (the pointersTo: follow-up) one whose title says how many objects point to it."
Class {
	#name : #DiscoverabilityTest,
	#superclass : #TestCase
}

{ #category : #helpers }
DiscoverabilityTest >> contextMenuOf: aTextView [
	^ aTextView subviews detect: [:v | v isKindOf: Menu] ifNone: [nil]
]

{ #category : #helpers }
DiscoverabilityTest >> describe: aValue class: aClass handle: aHandle [
	^ InspectorModelTest new describe: aValue class: aClass handle: aHandle name: nil
]

{ #category : #helpers }
DiscoverabilityTest >> openEveryTool [
	"A workspace, a browser, an inspector and a debugger on fake targets: their windows."
	| c w b i d t |
	c := FakeDevClient on: [:kind :args | self describe: '7' class: 'SmallInteger' handle: 5].
	w := DevTools openWorkspace: c.
	b := BrowserWindow on: (BrowserModel new client: BrowserModelTest new fake; yourself).
	b open.
	i := InspectorWindow on: (InspectorModel new client: c; yourself).
	i open.
	t := DebuggerModelTest new.
	d := DebuggerWindow on: (DebuggerModel new client: (FakeDevClient on: [:kind :args |
		kind = 'process.frames' ifTrue: [{t frame: 1 method: 'Foo>>foo:' receiverClass: 'Foo'}] ifFalse: [true]]); yourself).
	d open.
	^ {w. b. i. d}
]

{ #category : #running }
DiscoverabilityTest >> tearDown [
	DevTools reset
]

{ #category : #tests }
DiscoverabilityTest >> testABrowserNamesAcceptOnceAMethodIsEdited [
	| m w |
	m := BrowserModel new client: BrowserModelTest new fake; yourself.
	w := (BrowserWindow on: m) open.
	m refresh.
	m selectClass: 'Circle'.
	w edited.
	self deny: (m status includesSubstring: 'accept').
	m selectSelector: 'radius'.
	w edited.
	self assert: m status equals: '⌘S accept'
]

{ #category : #tests }
DiscoverabilityTest >> testAMenuItemRunsTheFocusedPanesKeyActionOnce [
	| c w |
	c := FakeDevClient on: [:kind :args | self describe: '7' class: 'SmallInteger' handle: 5].
	w := DevTools openWorkspace: c.
	w textView text: '3 + 4'.
	w textView focus.
	self assert: DevTools focusedPane == w textView.
	DevTools smalltalkItem: 11.
	self assert: c sentKinds equals: #('evaluate').
	self assert: (c sent first last at: 'source') equals: '3 + 4'.
	"Accept does not apply to a workspace: nothing happens."
	DevTools smalltalkItem: 14.
	self assert: c sentKinds equals: #('evaluate').
	"The context menu's Do it is the same action."
	(self contextMenuOf: w textView) choose: 11.
	self assert: c sentKinds equals: #('evaluate' 'evaluate')
]

{ #category : #tests }
DiscoverabilityTest >> testEachPanesContextMenuListsTheItemsThatApply [
	| tools titles |
	tools := self openEveryTool.
	titles := [:pane | ((self contextMenuOf: pane) items collect: [:i | i at: 2]) asArray].
	self assert: (titles value: (tools at: 1) textView)
		equals: #('Do it' 'Print it' 'Inspect it' 'Senders of it' 'Implementors of it' 'Browse it' 'Instances of it' 'Objects pointing to it').
	self assert: (titles value: (tools at: 2) sourceView) equals: #('Accept' 'Senders of it' 'Implementors of it' 'Browse it').
	self assert: (titles value: (tools at: 4) sourceView) equals: #('Accept' 'Senders of it' 'Implementors of it' 'Browse it').
	self assert: (titles value: (tools at: 4) workspaceView) equals: (titles value: (tools at: 1) textView)
]

{ #category : #tests }
DiscoverabilityTest >> testEveryBoundKeyIsAMenuItemsAndInTheShortcuts [
	| text panes |
	text := DevTools shortcutsText.
	panes := self openEveryTool inject: OrderedCollection new into: [:a :w | a addAll: w textPanes; yourself].
	self assert: panes size equals: 5.
	panes do: [:p |
		self assert: p boundKeys notEmpty.
		p boundKeys do: [:k |
			self assert: (DevTools smalltalkItems anySatisfy: [:i | (i at: 3) = k]).
			self assert: (text includesSubstring: (DevTools glyphsOf: k))]].
	DevTools toolsItems , DevTools smalltalkItems do: [:i |
		self assert: (text includesSubstring: (DevTools glyphsOf: (i at: 3)) , (String with: Character tab) , (i at: 2))].
	DevTools helpItems do: [:i | self assert: (text includesSubstring: (i at: 2))].
	(BrowserWindow toolbarItems , DebuggerWindow toolbarItems) do: [:i | self assert: (text includesSubstring: (i at: 2))].
	self assert: (DevTools glyphsOf: 'cmd-shift-n') equals: '⇧⌘N'.
	"The pointersTo: follow-up's item and its key, which no other menu takes."
	self assert: (text includesSubstring: '⇧⌘O' , (String with: Character tab) , 'Objects pointing to it').
	self assert: ((DevTools toolsItems , DevTools smalltalkItems) select: [:i | (i at: 3) = 'cmd-shift-o']) size equals: 1
]

{ #category : #tests }
DiscoverabilityTest >> testInstancesOfItOpensAnInspectorWithTheCount [
	| c w inspector |
	c := FakeDevClient on: [:kind :args |
		kind = 'inspect'
			ifTrue: [(self describe: '#(''a'' ''b'')' class: 'Array' handle: 9) at: 'slots' put: #(); yourself]
			ifFalse: [((args at: 'source') endsWith: 'instanceCount')
				ifTrue: [self describe: '53254' class: 'SmallInteger' handle: nil]
				ifFalse: [self describe: '#(''a'' ''b'')' class: 'Array' handle: 9]]].
	w := DevTools openWorkspace: c.
	w textView text: 'String'.
	w textView selectFrom: 3 to: 2.
	w textView pressKey: 'cmd-shift-i'.
	self assert: (c sent collect: [:s | s last at: 'source' ifAbsent: [nil]]) asArray
		equals: #('(String) instanceCount' '(String) allInstances: 1000' nil).
	inspector := (DevTools windowsOf: InspectorWindow) first.
	self assert: inspector model title equals: 'Array #(''a'' ''b'') (1000 of 53254 instances)'
]

{ #category : #tests }
DiscoverabilityTest >> testObjectsPointingToItOpensAnInspectorWithTheCount [
	| c w inspector |
	c := FakeDevClient on: [:kind :args | | src |
		src := args at: 'source' ifAbsent: [''].
		kind = 'inspect'
			ifTrue: [(self describe: '#(an Array)' class: 'Array' handle: 9) at: 'slots' put: #(); yourself]
			ifFalse: [(src endsWith: 'pointerCount')
				ifTrue: [self describe: '1532' class: 'SmallInteger' handle: nil]
				ifFalse: [(src endsWith: 'printString')
					ifTrue: [self describe: '''it''''s x''' class: 'String' handle: 11]
					ifFalse: [self describe: '#(an Array)' class: 'Array' handle: 9]]]].
	w := DevTools openWorkspace: c.
	w textView text: 'x'.
	w textView selectFrom: 1 to: 1.
	w textView pressKey: 'cmd-shift-o'.
	self assert: (c sent collect: [:s | s last at: 'source' ifAbsent: [nil]]) asArray
		equals: #('(x) pointerCount' '(x) pointersTo: 1000' '(x) printString' nil).
	inspector := (DevTools windowsOf: InspectorWindow) first.
	self assert: inspector model title equals: 'Array #(an Array) (1000 of 1532 objects pointing to it''s x)'.
	self assert: w model status equals: '1000 of 1532 objects pointing to it''s x'.
	"Under the limit, the count alone; one is an object."
	self assert: (DevTools objects: 3 pointingTo: 'nil' limit: 1000) equals: '3 objects pointing to nil'.
	self assert: (DevTools objects: 1 pointingTo: 'nil' limit: 1000) equals: '1 object pointing to nil'
]

{ #category : #tests }
DiscoverabilityTest >> testSendersImplementorsAndBrowseItOpenABrowser [
	| c w b t |
	t := BrowserModelTest new.
	c := FakeDevClient on: [:kind :args | kind = 'method.implementors' ifTrue: [#('Circle')] ifFalse: [t answer: kind args: args]].
	w := DevTools openWorkspace: c.
	w textView text: 'x at: 1 put: 2'.
	w textView selectFrom: 1 to: 14.
	w textView pressKey: 'cmd-shift-n'.
	b := (DevTools windowsOf: BrowserWindow) first.
	self assert: (c sent last last at: 'selector') equals: 'at:put:'.
	self assert: c sentKinds last equals: 'method.senders'.
	w textView text: 'radius'.
	w textView selectFrom: 3 to: 2.
	w textView pressKey: 'cmd-shift-m'.
	self assert: c sentKinds last equals: 'method.implementors'.
	self assert: (c sent last last at: 'selector') equals: 'radius'.
	w textView text: 'Circle'.
	w textView selectFrom: 1 to: 6.
	w textView pressKey: 'cmd-shift-b'.
	self assert: b model className equals: 'Circle'.
	self assert: (DevTools windowsOf: BrowserWindow) size equals: 1
]

{ #category : #tests }
DiscoverabilityTest >> testTheWorkspaceNamesItsKeysUntilTheFirstEvaluation [
	| c w |
	c := FakeDevClient on: [:kind :args | self describe: '7' class: 'SmallInteger' handle: 5].
	w := DevTools openWorkspace: c.
	self assert: w model status equals: '⌘D do it · ⌘P print it · ⌘I inspect it'.
	w textView text: '3 + 4'.
	w textView pressKey: 'cmd-d'.
	self assert: w model status equals: 'SmallInteger: 7'
]
