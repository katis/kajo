"Scrolling text (module 9a: lines appended, the demo's Transcript; module 9c: an editor). Offsets are the kernel's String positions: 1-based byte offsets of the UTF-8 text, a range start to stop inclusive (an empty one at start has stop start - 1); the shell converts them to its toolkit's. A selection, styles over ranges (colour, bold, background: syntax colouring, the debugger's current range), keys the view reports before it handles them (bindKeys:, onKey:: Cmd-S, Cmd-D), the text-changed event (onChange:), read-only mode (editable:), a monospace font, line and column from an offset and back. The text lives in the native view; nothing is mirrored here."
Class {
	#name : #TextView,
	#superclass : #View,
	#instVars : [
		'keyAction',
		'changeAction'
	],
	#category : #'Kernel-UI'
}

{ #category : #accessing }
TextView >> appendLine: aString [
	self call: 'appendLine' with: {aString}
]

{ #category : #accessing }
TextView >> clear [
	self call: 'clear' with: #()
]

{ #category : #accessing }
TextView >> headlessCall: aName with: anArray [
	| t |
	aName = 'clear' ifTrue: [^ self set: 'text' to: ''].
	aName = 'appendLine' ifTrue: [
		t := (self get: 'text') ifNil: [''].
		^ self set: 'text' to: (t isEmpty ifTrue: [anArray first] ifFalse: [t , (String with: Character lf) , anArray first])].
	aName = 'select' ifTrue: [^ self set: 'selection' to: anArray first printString , ' ' , (anArray at: 2) printString].
	aName = 'setStyles' ifTrue: [^ self set: 'styles' to: anArray].
	aName = 'scrollTo' ifTrue: [^ self set: 'scrolledTo' to: anArray first].
	^ nil
]

{ #category : #accessing }
TextView >> text [
	^ self get: 'text'
]

{ #category : #accessing }
TextView >> text: aString [
	self set: 'text' to: aString
]

{ #category : #editing }
TextView >> editable: aBoolean [
	"Read-only when false (the default of a new text view)."
	self set: 'editable' to: aBoolean
]

{ #category : #editing }
TextView >> isEditable [
	^ (self get: 'editable') == true
]

{ #category : #editing }
TextView >> scrollToOffset: anOffset [
	self call: 'scrollTo' with: {anOffset}
]

{ #category : #editing }
TextView >> selectFrom: start to: stop [
	"Select bytes start to stop (stop start - 1: the insertion point before start)."
	self call: 'select' with: {start. stop}
]

{ #category : #editing }
TextView >> selectedText [
	| s t |
	s := self selection.
	(s at: 2) < s first ifTrue: [^ ''].
	t := self text.
	^ t copyFrom: s first to: (s at: 2)
]

{ #category : #editing }
TextView >> selection [
	"{start. stop}: the selected bytes, or the insertion point (stop = start - 1)."
	| v f |
	v := self get: 'selection'.
	v isNil ifTrue: [^ {1. 0}].
	f := v substrings.
	^ {f first asInteger. (f at: 2) asInteger}
]

{ #category : #editing }
TextView >> styles: anArray [
	"Replace every range style at once (one view call): anArray is {start. stop. style} triples flat, a style 'color:<name>', 'background:<name>' or 'bold'. The colours are ADR 0010's names (red, green, blue, orange, gray, black, white) and the editor's (purple, brown, teal, yellow, highlight)."
	self call: 'setStyles' with: anArray
]

{ #category : #events }
TextView >> bindKeys: anArray [
	"The keys this view reports before handling them, as key events ('cmd-s', 'cmd-d', 'cmd-shift-p'); any other key the view handles as usual."
	self set: 'keys' to: (anArray inject: '' into: [:a :k | a isEmpty ifTrue: [k] ifFalse: [a , ' ' , k]])
]

{ #category : #events }
TextView >> handleEvent: anEvent [
	"A text event (the shell's Transcript lines in the demo) appends its value as a line; a key event runs the key action with the key's name; a textChanged event runs the change action."
	anEvent kind == #text ifTrue: [^ self appendLine: anEvent value displayString].
	anEvent kind == #key ifTrue: [^ keyAction ifNotNil: [:b | b cull: anEvent value cull: self]].
	anEvent kind == #textChanged ifTrue: [^ changeAction ifNotNil: [:b | b cull: self]]
]

{ #category : #events }
TextView >> onChange: aBlock [
	changeAction := aBlock
]

{ #category : #events }
TextView >> onKey: aBlock [
	keyAction := aBlock
]

{ #category : #lines }
TextView >> lineAndColumnOf: anOffset [
	"{line. column} of a byte offset of the text (both from 1; the column in bytes)."
	^ self class lineAndColumnOf: anOffset in: (self text ifNil: [''])
]

{ #category : #lines }
TextView >> offsetOfLine: aLine column: aColumn [
	^ self class offsetOfLine: aLine column: aColumn in: (self text ifNil: [''])
]

{ #category : #lines }
TextView class >> lineAndColumnOf: anOffset in: aString [
	| line lineStart limit |
	line := 1.
	lineStart := 1.
	limit := (anOffset - 1) min: aString byteSize.
	1 to: limit do: [:i | (aString byteAt: i) = 10 ifTrue: [line := line + 1. lineStart := i + 1]].
	^ {line. anOffset - lineStart + 1}
]

{ #category : #lines }
TextView class >> offsetOfLine: aLine column: aColumn in: aString [
	"The byte offset of a line and column (both from 1); past the end, the end plus one."
	| line i |
	line := 1.
	i := 1.
	[line < aLine and: [i <= aString byteSize]] whileTrue: [
		(aString byteAt: i) = 10 ifTrue: [line := line + 1].
		i := i + 1].
	^ (i + aColumn - 1) min: aString byteSize + 1
]

{ #category : #registry }
TextView class >> kind [
	^ 'textView'
]
