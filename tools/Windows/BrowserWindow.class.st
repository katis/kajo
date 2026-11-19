"The browser's window (module 9c): packages, the class tree, method categories and selectors side by side in a split view over the source pane, a toolbar, a context menu on the selectors, and a status line. Cmd-S accepts the pane; the source is coloured with the kernel's Scanner as it is edited, and a compile error's line is marked. Senders and implementors open a list of methods; double-clicking one goes there. The class tree is given to the outline whole (the tools' form; ADR 0010's Built (9c) note) or, for the measurement, on demand. Types 3 (docs/modules/types-3.md): the type checker's diagnostics of the shown method are marked in the source with a pale orange background over each one's range (the whole first line when it has none), not the compile error's red, and the selectors that have one carry a mark; Type diagnostics of the class or of the image (the Smalltalk menu) fill the messages list with one row per diagnostic."
Class {
	#name : #BrowserWindow,
	#superclass : #ToolWindow,
	#instVars : [
		'packagesTable',
		'classTree',
		'categoriesTable',
		'selectorsTable',
		'sourceView',
		'messagesWindow',
		'messagesTable',
		'treeIndex',
		'hinted'
	],
	#classInstVars : [
		'treeForm'
	]
}

{ #category : #accessing }
BrowserWindow >> classTree [
	^ classTree
]

{ #category : #accessing }
BrowserWindow >> messagesTable [
	"The messages list's table, or nil before it opened."
	^ messagesTable
]

{ #category : #accessing }
BrowserWindow >> selectorsTable [
	^ selectorsTable
]

{ #category : #accessing }
BrowserWindow >> sourceView [
	^ sourceView
]

{ #category : #actions }
BrowserWindow >> sourceKey: aKey [
	"A key of the source pane: Cmd-S accepts, the type diagnostics items list the shown class's or the image's diagnostics, the rest are the Smalltalk menu's."
	aKey = 'cmd-s' ifTrue: [^ model accept: sourceView text].
	aKey = 'cmd-shift-e' ifTrue: [
		model className isNil ifTrue: [^ model status: 'select a class to list its type diagnostics'].
		^ model listDiagnostics: model className].
	aKey = 'cmd-shift-d' ifTrue: [^ model listDiagnostics: nil].
	self key: aKey in: sourceView with: nil
]

{ #category : #actions }
BrowserWindow >> toolbarItem: anId [
	anId = 1 ifTrue: [^ model toggleSide].
	anId = 2 ifTrue: [^ model toggleByTag].
	anId = 3 ifTrue: [^ model selectSelector: nil].
	anId = 4 ifTrue: [^ model showComment].
	anId = 5 ifTrue: [^ model newMethodTemplate].
	anId = 6 ifTrue: [^ model newClassTemplate].
	anId = 7 ifTrue: [^ model senders].
	anId = 8 ifTrue: [^ model implementors].
	anId = 9 ifTrue: [^ model removeMethod].
	anId = 10 ifTrue: [^ model removeClass]
]

{ #category : #building }
BrowserWindow >> build [
	| split toolbar menu |
	self makeWindow: 'Browser'.
	split := window add: SplitView new.
	split x: 0 y: 0 width: 900 height: 250.
	split vertical: true.
	split autoresize: 'width'.
	packagesTable := split add: TableView new.
	packagesTable x: 0 y: 0 width: 180 height: 250.
	packagesTable columns: #('Packages').
	classTree := split add: OutlineView new.
	classTree x: 0 y: 0 width: 260 height: 250.
	categoriesTable := split add: TableView new.
	categoriesTable x: 0 y: 0 width: 200 height: 250.
	categoriesTable columns: #('Categories').
	selectorsTable := split add: TableView new.
	selectorsTable x: 0 y: 0 width: 260 height: 250.
	selectorsTable columns: #('Selectors').
	sourceView := self textAt: {0. 252. 900. 362} editable: true.
	sourceView autoresize: 'width height'.
	self pane: sourceView keys: (DevTools keysOfPane: 'Browser source') action: [:k | self sourceKey: k].
	self addStatusLine.
	toolbar := Toolbar new.
	BrowserWindow toolbarItems do: [:i | toolbar addItem: i first title: (i at: 2)].
	window toolbar: toolbar.
	toolbar action: [:id | self toolbarItem: id].
	menu := Menu new.
	menu title: 'Selector'.
	menu addItem: 7 title: 'Senders' key: nil; addItem: 8 title: 'Implementors' key: nil; addItem: 9 title: 'Remove method' key: nil.
	menu action: [:id | self toolbarItem: id].
	selectorsTable contextMenu: menu.
	packagesTable onSelect: [:row | model selectPackage: ((row between: 2 and: model packages size + 1) ifTrue: [model packages at: row - 1] ifFalse: [nil])].
	classTree onSelect: [:id | (model classOfId: id) ifNotNil: [:n | model selectClass: n]].
	classTree onExpand: [:id | self expand: id].
	categoriesTable onSelect: [:row | model selectCategory: ((row between: 1 and: model categories size) ifTrue: [model categories at: row] ifFalse: [nil])].
	selectorsTable onSelect: [:row | | sels |
		sels := model selectors.
		(row between: 1 and: sels size) ifTrue: [model selectSelector: (sels at: row)]].
	sourceView onChange: [:v | self edited. self colour]
]

{ #category : #building }
BrowserWindow >> defaultFrame [
	^ {60. 60. 900. 640}
]

{ #category : #closing }
BrowserWindow >> closed [
	messagesWindow isNil ifFalse: [messagesWindow close. messagesWindow := nil].
	super closed
]

{ #category : #updating }
BrowserWindow >> colour [
	"The source's styles: the Scanner's tokens, the type checker's diagnostics (Types 3), and the compile error's line last, so that it wins where they meet."
	| text styles |
	text := sourceView text ifNil: [''].
	styles := SourceColorer stylesFor: text pattern: (model sourceKind == #method or: [model sourceKind == #newMethod or: [model sourceKind == #signature]]).
	styles := styles , (self diagnosticStylesIn: text).
	model errorLine isNil ifFalse: [ | a b |
		a := TextView offsetOfLine: model errorLine column: 1 in: text.
		b := TextView offsetOfLine: model errorLine + 1 column: 1 in: text.
		b > a ifTrue: [styles := styles , {a. b - 1. 'background:red'}]].
	sourceView styles: styles
]

{ #category : #updating }
BrowserWindow >> diagnosticStylesIn: aText [
	"A background over each of the shown method's diagnostics: its range (start and end are byte offsets in the method's installed source, from 0, end exclusive; the styles' are bytes from 1, both ends in), or the whole first line when it has none or the range is not inside the text."
	| out |
	out := OrderedCollection new.
	model diagnostics do: [:d | | a b |
		a := d at: 'start'.
		b := d at: 'end'.
		(a isInteger and: [b isInteger and: [a >= 0 and: [b > a and: [b <= aText byteSize]]]])
			ifTrue: [out add: a + 1; add: b; add: BrowserWindow diagnosticStyle]
			ifFalse: [ | e |
				e := (TextView offsetOfLine: 2 column: 1 in: aText) - 1 min: aText byteSize.
				e >= 1 ifTrue: [out add: 1; add: e; add: BrowserWindow diagnosticStyle]]].
	^ out asArray
]

{ #category : #updating }
BrowserWindow >> edited [
	"The source pane was edited by hand: the type diagnostics' marks are dropped (Types 3), and with a method shown and no compile error named, the status line says how to accept it (once per method shown; the discoverability follow-up)."
	model sourceEdited.
	hinted == true ifTrue: [^ self].
	(model sourceKind == #method or: [model sourceKind == #newMethod]) ifFalse: [^ self].
	model errorLine isNil ifFalse: [^ self].
	hinted := true.
	model status: (DevTools glyphsOf: 'cmd-s') , ' accept'
]

{ #category : #updating }
BrowserWindow >> expand: anId [
	"The on-demand form: the children of anId."
	treeIndex isNil ifTrue: [^ self].
	classTree children: ((treeIndex at: anId ifAbsent: [#()]) collect: [:t | {t first. t at: 3. treeIndex includesKey: t first}]) asArray of: anId
]

{ #category : #updating }
BrowserWindow >> showClasses [
	"The class tree: the whole tree in one call (push), or the roots and each item's children when it is expanded (on demand)."
	| tree |
	tree := model classTree.
	BrowserWindow treeForm == #onDemand ifFalse: [^ classTree tree: tree].
	treeIndex := Dictionary new.
	tree do: [:t | (treeIndex at: (t at: 2) ifAbsentPut: [OrderedCollection new]) add: t].
	self expand: 0
]

{ #category : #updating }
BrowserWindow >> showMessages [
	messagesWindow isNil ifTrue: [
		messagesWindow := Window new.
		messagesWindow x: 980 y: 80 width: 420 height: 300.
		messagesTable := messagesWindow add: TableView new.
		messagesTable x: 0 y: 0 width: 420 height: 300.
		messagesTable autoresize: 'width height'.
		messagesTable onDoubleClick: [:row | model selectMessageAt: row].
		messagesWindow onClose: [:w | messagesWindow := nil. model listClosed]].
	messagesWindow title: model messagesTitle.
	messagesTable columns: model messageColumns.
	messagesTable rows: model messageRows.
	messagesWindow show
]

{ #category : #updating }
BrowserWindow >> showSelectors [
	"The selectors, each with a mark when the type checker has a diagnostic of it (Types 3)."
	| marked |
	marked := model diagnosedSelectors.
	selectorsTable list: (model selectors collect: [:s | (marked includes: s) ifTrue: [s , BrowserWindow diagnosticMark] ifFalse: [s]])
]

{ #category : #updating }
BrowserWindow >> update: anAspect [
	super update: anAspect.
	anAspect == #packages ifTrue: [^ packagesTable list: {'(all)'} , model packages].
	anAspect == #classes ifTrue: [^ self showClasses].
	anAspect == #class ifTrue: [^ window title: 'Browser: ' , (model className ifNil: [''])].
	anAspect == #side ifTrue: [^ self update: #class].
	anAspect == #categories ifTrue: [^ categoriesTable list: model categories].
	anAspect == #selectors ifTrue: [^ self showSelectors].
	anAspect == #selector ifTrue: [^ selectorsTable selectRow: ((model selectors indexOf: model selector) max: 0)].
	anAspect == #source ifTrue: [hinted := false. sourceView text: model source. ^ self colour].
	anAspect == #errorLine ifTrue: [^ self colour].
	anAspect == #messages ifTrue: [^ self showMessages].
	anAspect == #diagnostics ifTrue: [
		self showSelectors.
		self update: #selector.
		^ self colour]
]

{ #category : #building }
BrowserWindow class >> toolbarItems [
	"The toolbar's commands: id, title."
	^ #(#(1 'Instance/Class') #(2 'Hierarchy/Tag') #(3 'Definition') #(4 'Comment') #(5 'New method') #(6 'New class')
		#(7 'Senders') #(8 'Implementors') #(9 'Remove method') #(10 'Remove class'))
]

{ #category : #diagnostics }
BrowserWindow class >> diagnosticMark [
	"What a selector with a type diagnostic carries in the selectors table."
	^ '  ⚠'
]

{ #category : #diagnostics }
BrowserWindow class >> diagnosticStyle [
	"A diagnostic's mark in the source (Types 3): a background the hosts know (TextOffsets: color, background, bold), pale (macOS and UIKit draw a named background at 0.3 alpha), and neither the compile error's red nor the debugger's highlight."
	^ 'background:orange'
]

{ #category : #forms }
BrowserWindow class >> treeForm [
	"#push (the whole tree in one view call, the tools' form) or #onDemand (the measurement's alternative)."
	^ treeForm ifNil: [#push]
]

{ #category : #forms }
BrowserWindow class >> treeForm: aSymbol [
	treeForm := aSymbol
]
