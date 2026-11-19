"The tools' windows built headless (module 9c: the wrappers keep their properties without a shell): a browser shows a fake target's class tree, selectors and coloured source and accepts with Cmd-S; a debugger highlights the frame's range; DevTools opens a debugger on process.stopped and brings it back on the next stop of the same Process, and opens one for each stop session.open's answer lists (the development answers: a Process that stopped before the client came)."
Class {
	#name : #ToolWindowTest,
	#superclass : #TestCase
}

{ #category : #diagnostics }
ToolWindowTest >> styles: anArray at: aStart to: aStop are: aStyle [
	"Whether the flat styles anArray hold {aStart. aStop. aStyle}."
	1 to: anArray size - 2 by: 3 do: [:i |
		((anArray at: i) = aStart and: [(anArray at: i + 1) = aStop and: [(anArray at: i + 2) = aStyle]]) ifTrue: [^ true]].
	^ false
]

{ #category : #diagnostics }
ToolWindowTest >> testTheDiagnosticsListAndAClosedWindowStopsListening [
	| c m w |
	c := BrowserModelTest new diagnosedFake: [:args | BrowserModelTest new circleDiagnostics].
	m := BrowserModel new client: c; yourself.
	w := (BrowserWindow on: m) open.
	m refresh.
	m selectClass: 'Circle'.
	w sourceView pressKey: 'cmd-shift-e'.
	self assert: (w messagesTable get: 'columns') equals: #('Class' 'Side' 'Selector' 'Diagnostic').
	"The rows as the headless table keeps them: the column count, then the cells."
	self assert: ((w messagesTable get: 'rows') copyFrom: 2 to: 5) equals: #('Circle' 'instance' 'radius' 'Integer does not understand #foo').
	w sourceView pressKey: 'cmd-shift-d'.
	self assert: ((c sent select: [:s | s first = 'diagnostics']) last last at: 'className') isNil.
	w close.
	self deny: m isListing.
	c diagnosticsChanged: #('Circle>>radius').
	self assert: ((c sent select: [:s | s first = 'diagnostics']) size) equals: 3
]

{ #category : #diagnostics }
ToolWindowTest >> testTheSourceMarksEachDiagnosticAtItsBytes [
	"Types 3: a background over each diagnostic's range, in the bytes the styles use, after multi-byte characters; the whole first line for one without a range; the selectors that have one marked; the compile error's red line still there when both are, and its text on the status line."
	| src start c m w styles |
	src := 'radius
	"é, ü and ✓ first"
	^ radius zork'.
	start := (src indexOfSubstring: 'radius zork') - 1.
	c := FakeDevClient on: [:kind :args |
		kind = 'diagnostics'
			ifTrue: [FakeDevClient diagnostics: {
				FakeDevClient diagnostic: 'dnu' class: 'Circle' side: 'instance' selector: 'radius' line: 3 start: start end: start + 11 text: 'Integer does not understand #zork'.
				FakeDevClient diagnostic: 'checker' class: 'Circle' side: 'instance' selector: 'radius' line: 0 start: nil end: nil text: 'the checker failed here: x'}]
			ifFalse: [kind = 'method.source'
				ifTrue: [JsonObject new at: 'class' put: 'Circle'; at: 'selector' put: 'radius'; at: 'source' put: src; yourself]
				ifFalse: [BrowserModelTest new answer: kind args: args]]].
	m := BrowserModel new client: c; yourself.
	w := (BrowserWindow on: m) open.
	m refresh.
	m selectClass: 'Circle'.
	self assert: (w selectorsTable get: 'rows') equals: {1. 'drawOn:'. 'radius' , BrowserWindow diagnosticMark. 'radius:'}.
	m selectSelector: 'radius'.
	styles := w sourceView get: 'styles'.
	self assert: src byteSize - src scalarCount equals: 4.
	self assert: (self styles: styles at: start + 1 to: start + 11 are: 'background:orange').
	self assert: ((src copyFrom: start + 1 to: start + 11) = 'radius zork').
	self assert: (self styles: styles at: 1 to: 7 are: 'background:orange').
	self assert: m status equals: '2 type diagnostics: Integer does not understand #zork'.
	"A compile error: its line is red, after the marks, and its text wins the status line."
	m failed: 'CompileError: line 3: an expression expected'.
	styles := w sourceView get: 'styles'.
	self assert: (styles includes: 'background:red').
	self assert: (self styles: styles at: start + 1 to: start + 11 are: 'background:orange').
	self assert: (styles indexOf: 'background:red') > (styles size - (styles reversed indexOf: 'background:orange') + 1).
	self assert: m status equals: 'CompileError: line 3: an expression expected'.
	m noteDiagnostics.
	self assert: m status equals: 'CompileError: line 3: an expression expected'.
	"The first edit drops the marks."
	w sourceView text: src , ' '.
	w sourceView handleEvent: (UIEvent kind: #textChanged target: w sourceView handle value: nil time: 0).
	self deny: ((w sourceView get: 'styles') includes: 'background:orange').
	w close
]

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
