"A menu (module 9c): items with an id, a title and a key equivalent ('cmd-s'), submenus; installed in the application's menu bar (installInMenuBar) or as a view's context menu (View>>contextMenu:). Choosing an item runs the action with the item's id in the event loop."
Class {
	#name : #Menu,
	#superclass : #View,
	#instVars : [
		'action',
		'items'
	]
}

{ #category : #accessing }
Menu >> action: aBlock [
	"aBlock gets the chosen item's id."
	action := aBlock
]

{ #category : #accessing }
Menu >> add: aView [
	"A submenu is held like a subview (its wrapper lives while the menu does); the native menu is added by addSubmenu:."
	aView setSuperview: self.
	subviews add: aView.
	^ aView
]

{ #category : #accessing }
Menu >> addItem: anId title: aString key: aKeyOrNil [
	items isNil ifTrue: [items := OrderedCollection new].
	items add: {anId. aString. aKeyOrNil}.
	self call: 'addItem' with: {anId. aString. aKeyOrNil ifNil: ['']}
]

{ #category : #accessing }
Menu >> addSubmenu: aMenu [
	self add: aMenu.
	self call: 'addSubmenu' with: {aMenu handle}
]

{ #category : #accessing }
Menu >> installInMenuBar [
	self call: 'install' with: #()
]

{ #category : #accessing }
Menu >> items [
	^ items ifNil: [#()]
]

{ #category : #accessing }
Menu >> title: aString [
	self set: 'title' to: aString
]

{ #category : #accessing }
Menu >> uninstallFromMenuBar [
	"Take the menu out of the application's menu bar again (a test's menu)."
	self call: 'uninstall' with: #()
]

{ #category : #events }
Menu >> choose: anId [
	"What choosing an item does (the event loop sends it; tests may too)."
	action ifNotNil: [:b | b cull: anId]
]

{ #category : #events }
Menu >> handleEvent: anEvent [
	anEvent kind == #menu ifTrue: [self choose: anEvent value]
]

{ #category : #registry }
Menu class >> kind [
	^ 'menu'
]
