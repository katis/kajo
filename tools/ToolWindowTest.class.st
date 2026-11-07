"The tools' windows built headless (module 9c: the wrappers keep their properties without a shell): a browser shows a fake target's class tree, selectors and coloured source and accepts with Cmd-S; a debugger highlights the frame's range; DevTools opens a debugger on process.stopped and brings it back on the next stop of the same Process, and opens one for each stop session.open's answer lists (the development answers: a Process that stopped before the client came)."
Class {
	#name : #ToolWindowTest,
	#superclass : #TestCase,
	#category : #'Tools-Tests'
}

{ #category : #running }
ToolWindowTest >> tearDown [
	DevTools reset
]

{ #category : #tests }
ToolWindowTest >> testABrowserWindowShowsAndAccepts [
	| t m w |
	t := BrowserModelTest new.
	m := BrowserModel new client: t fake; yourself.
	w := (BrowserWindow on: m) open.
	m refresh.
	self assert: (w classTree get: 'tree') size equals: 15.
	m selectClass: 'Circle'.
	self assert: (w selectorsTable get: 'rows') equals: #(1 'drawOn:' 'radius' 'radius:').
	m selectSelector: 'radius'.
	self assert: (w sourceView text beginsWith: 'radius').
	self assert: ((w sourceView get: 'styles') includes: 'bold').
	w sourceView text: 'area
	^ 3'.
	w sourceView handleEvent: (UIEvent kind: #key target: w sourceView handle value: 'cmd-s' time: 0).
	self assert: m selector equals: 'area'.
	w close.
	self deny: w isOpen
]

{ #category : #tests }
ToolWindowTest >> testAStopOpensADebuggerAndTheNextStopReusesIt [
	| c t w w2 |
	t := DebuggerModelTest new.
	c := FakeDevClient on: [:kind :args | kind = 'process.frames' ifTrue: [{t frame: 1 method: 'Foo>>foo:' receiverClass: 'Foo'}] ifFalse: [true]].
	DevTools register: c.
	c event: 'process.stopped' with: {'process'. 42. 'reason'. 'error'. 'error'. 'Error: boom'}.
	self assert: DevTools debuggers size equals: 1.
	w := DevTools debuggers first.
	self assert: w model frameTitles equals: #('Foo>>foo:').
	self assert: ((w sourceView get: 'styles') includes: 'background:highlight').
	c event: 'process.resumed' with: {'process'. 42}.
	self assert: w model state equals: #running.
	c event: 'process.stopped' with: {'process'. 42. 'reason'. 'step'. 'error'. 'step'}.
	w2 := DevTools debuggers detect: [:d | d isOpen].
	self assert: w2 == w.
	self assert: w model reason equals: 'step'.
	self assert: DevTools transcript lines isEmpty
]

{ #category : #tests }
ToolWindowTest >> testTheStopsStandingWhenTheSessionOpensOpenDebuggers [
	| c t info stop |
	t := DebuggerModelTest new.
	c := FakeDevClient on: [:kind :args | kind = 'process.frames' ifTrue: [{t frame: 1 method: 'Foo>>foo:' receiverClass: 'Foo'}] ifFalse: [true]].
	DevTools register: c.
	stop := JsonObject new.
	stop at: 'process' put: 7; at: 'reason' put: 'error'; at: 'error' put: 'MessageNotUnderstood: a Foo does not understand #bar'.
	info := JsonObject new.
	info at: 'protocol' put: 1; at: 'stopped' put: (Array with: stop).
	c emit: 'connection.open' with: info.
	self assert: DevTools debuggers size equals: 1.
	self assert: DevTools debuggers first model process equals: 7.
	self assert: DevTools debuggers first model frameTitles equals: #('Foo>>foo:').
	"A target with no stops, or one older than the list, opens none."
	DevTools reset.
	DevTools register: c.
	c emit: 'connection.open' with: (JsonObject new at: 'protocol' put: 1; yourself).
	self assert: DevTools debuggers isEmpty
]
