"Rows of Strings under titled columns (module 9c; one column is a list). The shell's data source holds the rows it was given: all at once (rows:), or a row count and pages of rows on demand (rowCount:, the expand event with the first row of a page the table needs, rows:at:). Rows are numbered from 1; selection and double-click events carry the row (0: none)."
Class {
	#name : #TableView,
	#superclass : #View,
	#instVars : [
		'selectAction',
		'doubleClickAction',
		'pageAction'
	],
	#category : #'Kernel-UI'
}

{ #category : #events }
TableView >> handleEvent: anEvent [
	anEvent kind == #selectionChanged ifTrue: [^ selectAction ifNotNil: [:b | b cull: anEvent value]].
	anEvent kind == #doubleClick ifTrue: [^ doubleClickAction ifNotNil: [:b | b cull: anEvent value]].
	anEvent kind == #expand ifTrue: [^ pageAction ifNotNil: [:b | b cull: anEvent value]]
]

{ #category : #events }
TableView >> onDoubleClick: aBlock [
	doubleClickAction := aBlock
]

{ #category : #events }
TableView >> onPage: aBlock [
	"aBlock gets the first row of a page the table needs (the on-demand form)."
	pageAction := aBlock
]

{ #category : #events }
TableView >> onSelect: aBlock [
	selectAction := aBlock
]

{ #category : #rows }
TableView >> columns: anArray [
	"The columns' titles (one view call)."
	self call: 'setColumns' with: anArray asArray
]

{ #category : #rows }
TableView >> flat: anArray [
	| n out |
	n := anArray isEmpty ifTrue: [1] ifFalse: [anArray first size].
	out := OrderedCollection new.
	out add: n.
	anArray do: [:r | r do: [:c | out add: c]].
	^ out asArray
]

{ #category : #rows }
TableView >> headlessCall: aName with: anArray [
	aName = 'setColumns' ifTrue: [^ self set: 'columns' to: anArray].
	aName = 'setRows' ifTrue: [^ self set: 'rows' to: anArray].
	aName = 'setRowCount' ifTrue: [^ self set: 'rowCount' to: anArray first].
	aName = 'setRowsAt' ifTrue: [^ self set: 'page' to: anArray].
	aName = 'selectRow' ifTrue: [^ self set: 'selected' to: anArray first].
	^ nil
]

{ #category : #rows }
TableView >> list: aCollection [
	"One column of Strings."
	self rows: (aCollection collect: [:s | {s}]) asArray
]

{ #category : #rows }
TableView >> rowCount: anInteger [
	"The on-demand form: the table has anInteger rows and asks for pages of them as it shows them (onPage:)."
	self call: 'setRowCount' with: {anInteger}
]

{ #category : #rows }
TableView >> rows: anArray [
	"Every row at once: anArray of Arrays of Strings, as many as there are columns (one view call)."
	self call: 'setRows' with: (self flat: anArray)
]

{ #category : #rows }
TableView >> rows: anArray at: aFirstRow [
	"Rows aFirstRow on, for the on-demand form."
	self call: 'setRowsAt' with: {aFirstRow} , (self flat: anArray)
]

{ #category : #rows }
TableView >> selectRow: anInteger [
	self call: 'selectRow' with: {anInteger}
]

{ #category : #rows }
TableView >> selectedRow [
	^ (self get: 'selected') ifNil: [0]
]

{ #category : #registry }
TableView class >> kind [
	^ 'table'
]
