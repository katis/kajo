"A tree of items (module 9c): each item an id the Smalltalk side chooses (a positive SmallInteger), a title and whether it has children. The shell's data source holds what it was given; the Smalltalk side gives it either the whole tree at once (children:of: for every parent, in one turn) or the roots first and an item's children when the user expands it (the expand event, onExpand:; ADR 0010's Built (9c) note says which the tools use and why). Selection and double-click events carry the item's id (0: none)."
Class {
	#name : #OutlineView,
	#superclass : #View,
	#instVars : [
		'selectAction',
		'doubleClickAction',
		'expandAction'
	],
	#category : #'Kernel-UI'
}

{ #category : #events }
OutlineView >> handleEvent: anEvent [
	anEvent kind == #selectionChanged ifTrue: [^ selectAction ifNotNil: [:b | b cull: anEvent value]].
	anEvent kind == #doubleClick ifTrue: [^ doubleClickAction ifNotNil: [:b | b cull: anEvent value]].
	anEvent kind == #expand ifTrue: [^ expandAction ifNotNil: [:b | b cull: anEvent value]]
]

{ #category : #events }
OutlineView >> onDoubleClick: aBlock [
	doubleClickAction := aBlock
]

{ #category : #events }
OutlineView >> onExpand: aBlock [
	"aBlock gets the id of an item the user expanded whose children were not given yet."
	expandAction := aBlock
]

{ #category : #events }
OutlineView >> onSelect: aBlock [
	selectAction := aBlock
]

{ #category : #items }
OutlineView >> children: anArray of: aParentId [
	"The children of aParentId (0: the roots) are anArray of {id. title. hasChildren} triples, replacing any it had; one view call."
	| flat |
	flat := OrderedCollection new.
	flat add: aParentId.
	anArray do: [:t | flat add: t first; add: (t at: 2); add: (t at: 3)].
	self call: 'setChildren' with: flat asArray
]

{ #category : #items }
OutlineView >> expand: anId [
	self call: 'expand' with: {anId}
]

{ #category : #items }
OutlineView >> expandAll [
	self call: 'expandAll' with: #()
]

{ #category : #items }
OutlineView >> headlessCall: aName with: anArray [
	| d |
	aName = 'setChildren' ifTrue: [
		d := (self get: 'children') ifNil: [self set: 'children' to: Dictionary new].
		^ d at: anArray first put: (anArray copyFrom: 2 to: anArray size)].
	aName = 'setTree' ifTrue: [^ self set: 'tree' to: anArray].
	aName = 'select' ifTrue: [^ self set: 'selected' to: anArray first].
	^ nil
]

{ #category : #items }
OutlineView >> select: anId [
	self call: 'select' with: {anId}
]

{ #category : #items }
OutlineView >> selectedId [
	^ (self get: 'selected') ifNil: [0]
]

{ #category : #items }
OutlineView >> tree: anArray [
	"The whole tree at once: anArray is {id. parentId. title} triples, parents before their children (one view call)."
	| flat |
	flat := OrderedCollection new.
	anArray do: [:t | flat add: t first; add: (t at: 2); add: (t at: 3)].
	self call: 'setTree' with: flat asArray
]

{ #category : #registry }
OutlineView class >> kind [
	^ 'outline'
]
