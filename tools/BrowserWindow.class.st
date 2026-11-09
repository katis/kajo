"The browser's window (module 9c): packages, the class tree, method categories and selectors side by side in a split view over the source pane, a toolbar, a context menu on the selectors, and a status line. Cmd-S accepts the pane; the source is coloured with the kernel's Scanner as it is edited, and a compile error's line is marked. Senders and implementors open a list of methods; double-clicking one goes there. The class tree is given to the outline whole (the tools' form; ADR 0010's Built (9c) note) or, for the measurement, on demand."
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
	],
	#category : #'Tools-Windows'
}

{ #category : #accessing }
BrowserWindow >> classTree [
	^ classTree
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
	self pane: sourceView keys: (DevTools keysOfPane: 'Browser source') action: [:k |
		k = 'cmd-s' ifTrue: [model accept: sourceView text] ifFalse: [self key: k in: sourceView with: nil]].
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
	sourceView onChange: [:v | self colour. self edited]
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
	"The source's styles: the Scanner's tokens, and the compile error's line."
	| text styles |
	text := sourceView text ifNil: [''].
	styles := SourceColorer stylesFor: text pattern: (model sourceKind == #method or: [model sourceKind == #newMethod]).
	model errorLine isNil ifFalse: [ | a b |
		a := TextView offsetOfLine: model errorLine column: 1 in: text.
		b := TextView offsetOfLine: model errorLine + 1 column: 1 in: text.
		b > a ifTrue: [styles := styles , {a. b - 1. 'background:red'}]].
	sourceView styles: styles
]

{ #category : #updating }
BrowserWindow >> edited [
	"The source pane was edited by hand: with a method shown and no compile error named, the status line says how to accept it (once per method shown; the discoverability follow-up)."
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
		messagesTable columns: #('Method').
		messagesTable onDoubleClick: [:row | (row between: 1 and: model messages size) ifTrue: [model selectMessage: (model messages at: row)]].
		messagesWindow onClose: [:w | messagesWindow := nil]].
	messagesWindow title: model messagesTitle.
	messagesTable list: model messages.
	messagesWindow show
]

{ #category : #updating }
BrowserWindow >> update: anAspect [
	super update: anAspect.
	anAspect == #packages ifTrue: [^ packagesTable list: {'(all)'} , model packages].
	anAspect == #classes ifTrue: [^ self showClasses].
	anAspect == #class ifTrue: [^ window title: 'Browser: ' , (model className ifNil: [''])].
	anAspect == #side ifTrue: [^ self update: #class].
	anAspect == #categories ifTrue: [^ categoriesTable list: model categories].
	anAspect == #selectors ifTrue: [^ selectorsTable list: model selectors].
	anAspect == #selector ifTrue: [^ selectorsTable selectRow: ((model selectors indexOf: model selector) max: 0)].
	anAspect == #source ifTrue: [hinted := false. sourceView text: model source. ^ self colour].
	anAspect == #errorLine ifTrue: [^ self colour].
	anAspect == #messages ifTrue: [^ self showMessages]
]

{ #category : #building }
BrowserWindow class >> toolbarItems [
	"The toolbar's commands: id, title."
	^ #(#(1 'Instance/Class') #(2 'Hierarchy/Tag') #(3 'Definition') #(4 'Comment') #(5 'New method') #(6 'New class')
		#(7 'Senders') #(8 'Implementors') #(9 'Remove method') #(10 'Remove class'))
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
