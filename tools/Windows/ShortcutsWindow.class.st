"Help > Keyboard Shortcuts (the discoverability follow-up): a read-only text window listing every binding of the tools, DevTools shortcutsText, made from the menus' item lists so it cannot drift."
Class {
	#name : #ShortcutsWindow,
	#superclass : #ToolWindow,
	#instVars : [
		'textView'
	]
}

{ #category : #accessing }
ShortcutsWindow >> textView [
	^ textView
]

{ #category : #building }
ShortcutsWindow >> aspects [
	^ #()
]

{ #category : #building }
ShortcutsWindow >> build [
	self makeWindow: 'Keyboard Shortcuts'.
	textView := self textAt: {0. 0. 560. 520} editable: false.
	textView autoresize: 'width height'.
	textView text: DevTools shortcutsText
]

{ #category : #building }
ShortcutsWindow >> defaultFrame [
	^ {160. 100. 560. 520}
]
