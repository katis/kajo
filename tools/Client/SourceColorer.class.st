"Syntax colouring of a method's source with the kernel's Scanner (module 9c): the styles a TextView takes (styles:), {start. stop. style} triples over byte offsets. The message pattern is bold; keywords and binary selectors keep the text's colour; pseudo-variables are teal, other identifiers starting with a capital (globals) purple, literals (numbers, characters, strings, symbols, literal arrays' brackets) brown and green, comments gray. A source the Scanner cannot read is coloured up to where it stopped."
Class {
	#name : #SourceColorer,
	#superclass : #Object
}

{ #category : #colouring }
SourceColorer class >> commentsIn: aString from: start to: stop into: out [
	"The comments between two tokens: every quoted run in bytes start to stop."
	| i j |
	i := start.
	[i <= stop] whileTrue: [
		(aString byteAt: i) = 34
			ifTrue: [
				j := i + 1.
				[j <= stop and: [(aString byteAt: j) ~= 34]] whileTrue: [j := j + 1].
				out add: i; add: (j min: stop); add: 'color:gray'.
				i := j + 1]
			ifFalse: [i := i + 1]]
]

{ #category : #colouring }
SourceColorer class >> styleOf: aKind value: aValue [
	(aKind == #string or: [aKind == #symbol]) ifTrue: [^ 'color:brown'].
	(aKind == #integer or: [aKind == #float or: [aKind == #character]]) ifTrue: [^ 'color:green'].
	(aKind == #literalArrayStart or: [aKind == #byteArrayStart]) ifTrue: [^ 'color:brown'].
	aKind == #identifier ifTrue: [
		(#('self' 'super' 'thisContext' 'true' 'false' 'nil') includes: aValue) ifTrue: [^ 'color:teal'].
		((aValue byteAt: 1) between: 65 and: 90) ifTrue: [^ 'color:purple']].
	^ nil
]

{ #category : #colouring }
SourceColorer class >> stylesFor: aString [
	"The styles of a method source."
	^ self stylesFor: aString pattern: true
]

{ #category : #colouring }
SourceColorer class >> stylesFor: aString pattern: aBoolean [
	"The styles of a method source (aBoolean: its message pattern is bold) or of a doit."
	| out s last patternEnd |
	out := OrderedCollection new.
	aString isEmptyOrNil ifTrue: [^ #()].
	patternEnd := aBoolean
		ifTrue: [[Scanner patternEndIn: aString] on: Error do: [:e | 0]]
		ifFalse: [0].
	patternEnd > 0 ifTrue: [out add: 1; add: patternEnd; add: 'bold'].
	s := Scanner on: aString.
	last := 1.
	[[s next ~~ #end] whileTrue: [
		self commentsIn: aString from: last to: s start - 1 into: out.
		(self styleOf: s kind value: s value) ifNotNil: [:st | out add: s start; add: s stop - 1; add: st].
		last := s stop]] on: Error do: [:e | ^ out asArray].
	self commentsIn: aString from: last to: aString byteSize into: out.
	^ out asArray
]
