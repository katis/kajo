"Module 9c's wrappers on whatever host runs the suite (headless, AppKit in the Mac shell's tests mode, UIKit on the phone): a text view's selection, styles, keys and lines; an outline's children and tree; a table's rows and pages; a menu's and a toolbar's items; the event loop's actions by kind and its timers' tokens. The tests ask the host what it supports rather than assume the headless one: a kind the toolkit lacks (View class>>supports:) must be refused with an error and the rest of that case is skipped; what the native view holds and the protocol has no get for is read back only where the wrapper keeps it itself (readsBack:); a timer is a token with a host and nil without (ClientTransport hasHost). tearDown leaves the main thread, as ViewTest's does."
Class {
	#name : #ViewWrapperTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #helpers }
ViewWrapperTest >> assertRefused: aViewClass [
	"A host without aViewClass's kind refuses to make one with an error a test can catch, not a trap."
	self should: [aViewClass new] raise: Error
]

{ #category : #helpers }
ViewWrapperTest >> dispatchQueuedEvents: aBlock [
	"Hand every event the host queued to its wrapper, as the event loop would, until aBlock answers true or nothing is queued. Without a running loop (the tests mode starts none) the queue is drained here; with one, wait for it (at most 5 s)."
	| a deadline |
	UIEventLoop isRunning ifFalse: [
		[(a := UIEventLoop nextEvent) notNil] whileTrue: [UIEventLoop dispatch: (UIEvent fromArray: a)].
		^ self].
	deadline := Smalltalk microsecondClock + 5000000.
	[aBlock value or: [Smalltalk microsecondClock > deadline]] whileFalse: [(Delay forMilliseconds: 10) wait]
]

{ #category : #helpers }
ViewWrapperTest >> press: aKey in: aTextView [
	"Deliver aKey to aTextView through the host (simulateKey:emulating:): through the application once its window is the key window (asked for, then waited for at most 2 s), else in AppKit's documented order for a key window. Answers how, and says so on the Transcript, so a run tells which path it measured."
	| how deadline |
	deadline := Smalltalk microsecondClock + 2000000.
	[(how := aTextView simulateKey: aKey emulating: false) = 'notKey' and: [Smalltalk microsecondClock < deadline]]
		whileTrue: [(Delay forMilliseconds: 20) wait].
	how = 'notKey' ifTrue: [how := aTextView simulateKey: aKey emulating: true].
	Transcript showLine: 'ViewWrapperTest one key, one action: ' , aKey , ' delivered ' , how printString.
	^ how
]

{ #category : #helpers }
ViewWrapperTest >> readsBack: aView [
	"Whether what aView was given can be read back: a text view's styles and keys, an outline's children and tree, a table's rows and page. On AppKit and UIKit the native view holds them and the protocol has no get for them (nothing the toolkit holds is mirrored, module 9c); only the headless wrapper, which keeps its properties itself, answers them."
	^ aView isHeadless
]

{ #category : #running }
ViewWrapperTest >> tearDown [
	ProcessorScheduler detachFromMain
]

{ #category : #tests }
ViewWrapperTest >> testATextViewsSelectionStylesAndKeys [
	| t keys changed |
	t := TextView new.
	t text: 'foo
	^ bar'.
	t selectFrom: 6 to: 10.
	self assert: t selection equals: #(6 10).
	self assert: t selectedText equals: '^ bar'.
	t styles: #(1 3 'bold').
	"Styling changes neither the text nor the selection, on every host."
	self assert: t selection equals: #(6 10).
	self assert: t selectedText equals: '^ bar'.
	(self readsBack: t) ifTrue: [self assert: (t get: 'styles') equals: #(1 3 'bold')].
	t bindKeys: #('cmd-s' 'cmd-d').
	(self readsBack: t) ifTrue: [self assert: (t get: 'keys') equals: 'cmd-s cmd-d'].
	keys := OrderedCollection new.
	t onKey: [:k | keys add: k].
	t onChange: [:v | changed := v].
	t handleEvent: (UIEvent kind: #key target: t handle value: 'cmd-s' time: 0).
	t handleEvent: (UIEvent kind: #textChanged target: t handle value: nil time: 0).
	self assert: keys asArray equals: #('cmd-s').
	self assert: changed == t.
	t editable: true.
	self assert: t isEditable
]

{ #category : #tests }
ViewWrapperTest >> testLinesAndColumns [
	| s |
	s := 'ab
cde
f'.
	self assert: (TextView lineAndColumnOf: 1 in: s) equals: #(1 1).
	self assert: (TextView lineAndColumnOf: 5 in: s) equals: #(2 2).
	self assert: (TextView lineAndColumnOf: 8 in: s) equals: #(3 1).
	self assert: (TextView offsetOfLine: 2 column: 2 in: s) equals: 5.
	self assert: (TextView offsetOfLine: 9 column: 1 in: s) equals: 9
]

{ #category : #tests }
ViewWrapperTest >> testMenusAndToolbars [
	| m sub b chosen w v |
	(View supports: Menu kind)
		ifFalse: [self assertRefused: Menu]
		ifTrue: [
			m := Menu new.
			m title: 'Tools'.
			m addItem: 1 title: 'Browser' key: 'cmd-b'.
			sub := Menu new.
			m addSubmenu: sub.
			self assert: m items size equals: 1.
			self assert: (m subviews includes: sub).
			m action: [:id | chosen := id].
			m handleEvent: (UIEvent kind: #menu target: m handle value: 1 time: 0).
			self assert: chosen equals: 1.
			v := Window new add: TextView new.
			v contextMenu: m.
			self assert: (v subviews includes: m)].
	(View supports: Toolbar kind) ifFalse: [^ self assertRefused: Toolbar].
	b := Toolbar new.
	b addItem: 7 title: 'Proceed'.
	b action: [:id | chosen := id].
	w := Window new.
	w toolbar: b.
	b handleEvent: (UIEvent kind: #menu target: b handle value: 7 time: 0).
	self assert: chosen equals: 7.
	self assert: (w subviews includes: b)
]

{ #category : #tests }
ViewWrapperTest >> testOneKeyOneActionBetweenAViewAndTheMenuBar [
	"The discoverability follow-up: a key a focused text view binds that is also a menu item's key equivalent in the menu bar (the Smalltalk menu's Do it, Cmd-D) runs the view's key action exactly once and the menu's not at all; a key the view does not bind reaches the menu exactly once. Measured through the host's own key path (simulateKey:emulating: sends the key-down through the application when its window can be the key window, else offers it to the window's views and then to the menu bar as AppKit does for a key window; the Transcript line says which), so where there is no window server (headless) or no menu bar (UIKit) only the wrapper's side is checked: pressKey: runs a bound key's action and refuses another."
	| w t m viewKeys menuIds |
	viewKeys := OrderedCollection new.
	menuIds := OrderedCollection new.
	w := Window new.
	w x: 120 y: 120 width: 320 height: 200.
	t := w add: TextView new.
	t x: 0 y: 0 width: 320 height: 200.
	t editable: true.
	t bindKeys: #('cmd-d').
	t onKey: [:k | viewKeys add: k].
	self assert: t boundKeys equals: #('cmd-d').
	self assert: (t pressKey: 'cmd-d').
	self deny: (t pressKey: 'cmd-e').
	self assert: viewKeys asArray equals: #('cmd-d').
	viewKeys removeAll: viewKeys copy.
	(View hasShell and: [View supports: Menu kind]) ifFalse: [^ self].
	m := Menu new.
	m title: 'KeyTest'.
	m addItem: 1 title: 'Do it' key: 'cmd-d'; addItem: 2 title: 'Other' key: 'cmd-e'.
	m action: [:id | menuIds add: id].
	m installInMenuBar.
	[w show.
	t focus.
	self assert: t isFocused.
	self assert: ((self press: 'cmd-d' in: t) isKindOf: String).
	self dispatchQueuedEvents: [viewKeys notEmpty].
	self assert: viewKeys asArray equals: #('cmd-d').
	self assert: menuIds asArray equals: #().
	self assert: ((self press: 'cmd-e' in: t) isKindOf: String).
	self dispatchQueuedEvents: [menuIds notEmpty].
	self assert: viewKeys asArray equals: #('cmd-d').
	self assert: menuIds asArray equals: #(2)]
		ensure: [m uninstallFromMenuBar. w close]
]

{ #category : #tests }
ViewWrapperTest >> testOutlinesAndTables [
	| o t chosen |
	(View supports: OutlineView kind)
		ifFalse: [self assertRefused: OutlineView]
		ifTrue: [
			o := OutlineView new.
			o children: #(#(1 'Object' true) #(2 'Proto' false)) of: 0.
			(self readsBack: o) ifTrue: [self assert: ((o get: 'children') at: 0) equals: #(1 'Object' true 2 'Proto' false)].
			o tree: #(#(1 0 'Object') #(3 1 'Shape')).
			(self readsBack: o) ifTrue: [self assert: (o get: 'tree') equals: #(1 0 'Object' 3 1 'Shape')].
			o onSelect: [:id | chosen := id].
			o handleEvent: (UIEvent kind: #selectionChanged target: o handle value: 3 time: 0).
			self assert: chosen equals: 3.
			o onExpand: [:id | chosen := id negated].
			o handleEvent: (UIEvent kind: #expand target: o handle value: 1 time: 0).
			self assert: chosen equals: -1].
	(View supports: TableView kind) ifFalse: [^ self assertRefused: TableView].
	t := TableView new.
	t columns: #('Name' 'Value').
	t rows: #(#('a' '1') #('b' '2')).
	(self readsBack: t) ifTrue: [self assert: (t get: 'rows') equals: #(2 'a' '1' 'b' '2')].
	t rowCount: 20000.
	t rows: #(#('x' 'y')) at: 101.
	(self readsBack: t) ifTrue: [self assert: (t get: 'page') equals: #(101 2 'x' 'y')].
	t onDoubleClick: [:row | chosen := row].
	t handleEvent: (UIEvent kind: #doubleClick target: t handle value: 2 time: 0).
	self assert: chosen equals: 2
]

{ #category : #tests }
ViewWrapperTest >> testTheEventLoopsKindActionsAndTimers [
	| got token |
	UIEventLoop on: #line do: [:e | got := e value].
	UIEventLoop dispatch: (UIEvent kind: #line target: 1 value: '{}' time: 0).
	self assert: got equals: '{}'.
	token := UIEventLoop after: 10 do: [got := #fired].
	ClientTransport hasHost
		ifTrue: [
			"A host posts the timer and answers its token; cancelled, its event finds no block."
			self assert: (token isInteger and: [token > 0]).
			UIEventLoop cancelTimer: token]
		ifFalse: [
			"Without a host to post it a timer cannot be asked for."
			self assert: token isNil].
	UIEventLoop dispatch: (UIEvent kind: #timer target: 99 value: nil time: 0).
	self assert: got equals: '{}'.
	self assert: (UIEvent fromArray: #(15 3 nil 0)) kind equals: #textChanged.
	self assert: (UIEvent fromArray: #(12 3 '{}' 0)) kind equals: #line
]
