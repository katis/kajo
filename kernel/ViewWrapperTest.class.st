"Module 9c's wrappers headless (the same protocol the shells implement): a text view's selection, styles, keys and lines; an outline's children and tree; a table's rows and pages; a menu's and a toolbar's items; the event loop's actions by kind and its timers' tokens."
Class {
	#name : #ViewWrapperTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

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
	self assert: (t get: 'styles') equals: #(1 3 'bold').
	t bindKeys: #('cmd-s' 'cmd-d').
	self assert: (t get: 'keys') equals: 'cmd-s cmd-d'.
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
	| m sub b chosen w |
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
	b := Toolbar new.
	b addItem: 7 title: 'Proceed'.
	b action: [:id | chosen := id].
	w := Window new.
	w toolbar: b.
	b handleEvent: (UIEvent kind: #menu target: b handle value: 7 time: 0).
	self assert: chosen equals: 7.
	(w add: TextView new) contextMenu: m.
	self assert: (w subviews includes: b)
]

{ #category : #tests }
ViewWrapperTest >> testOutlinesAndTables [
	| o t chosen |
	o := OutlineView new.
	o children: #(#(1 'Object' true) #(2 'Proto' false)) of: 0.
	self assert: ((o get: 'children') at: 0) equals: #(1 'Object' true 2 'Proto' false).
	o tree: #(#(1 0 'Object') #(3 1 'Shape')).
	self assert: (o get: 'tree') equals: #(1 0 'Object' 3 1 'Shape').
	o onSelect: [:id | chosen := id].
	o handleEvent: (UIEvent kind: #selectionChanged target: o handle value: 3 time: 0).
	self assert: chosen equals: 3.
	o onExpand: [:id | chosen := id negated].
	o handleEvent: (UIEvent kind: #expand target: o handle value: 1 time: 0).
	self assert: chosen equals: -1.
	t := TableView new.
	t columns: #('Name' 'Value').
	t rows: #(#('a' '1') #('b' '2')).
	self assert: (t get: 'rows') equals: #(2 'a' '1' 'b' '2').
	t rowCount: 20000.
	t rows: #(#('x' 'y')) at: 101.
	self assert: (t get: 'page') equals: #(101 2 'x' 'y').
	t onDoubleClick: [:row | chosen := row].
	t handleEvent: (UIEvent kind: #doubleClick target: t handle value: 2 time: 0).
	self assert: chosen equals: 2
]

{ #category : #tests }
ViewWrapperTest >> testTheEventLoopsKindActionsAndTimers [
	| got |
	UIEventLoop on: #line do: [:e | got := e value].
	UIEventLoop dispatch: (UIEvent kind: #line target: 1 value: '{}' time: 0).
	self assert: got equals: '{}'.
	"Without a host to post it a timer cannot be asked for."
	self assert: (UIEventLoop after: 10 do: [got := #fired]) isNil.
	UIEventLoop dispatch: (UIEvent kind: #timer target: 99 value: nil time: 0).
	self assert: got equals: '{}'.
	self assert: (UIEvent fromArray: #(15 3 nil 0)) kind equals: #textChanged.
	self assert: (UIEvent fromArray: #(12 3 '{}' 0)) kind equals: #line
]
