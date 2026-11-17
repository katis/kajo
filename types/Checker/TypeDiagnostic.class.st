"One finding of the checker, never a refusal. kind: #dnu (the receiver's type does not understand the selector), #maybeNil (a send to a type that includes Nil, which does not understand it), #argType (an argument is not of the parameter's type), #arity (a block literal with the wrong number of arguments), #blockResult (a block literal answers the wrong type), #returnType, #assignType, #annotation (a type written in a pattern or a class definition does not read: an unknown class name, a malformed class-level type), #signature (a signature without a method that no class answers, or that contradicts what it narrows; docs/modules/types-2.md), #parse (a method's source does not parse) and #checker (the checker itself failed on the method: its fault, said, never hidden). where is the method's key, Class>>selector or Class class>>selector; behavior and selector name it; line is its source's line (1 for a signature), start and end the node's source range or nil."
Class {
	#name : #TypeDiagnostic,
	#superclass : #Object,
	#instVars : [
		'kind',
		'where',
		'line',
		'text',
		'sourceStart',
		'sourceEnd',
		'behavior',
		'selector'
	]
}

{ #category : #accessing }
TypeDiagnostic >> behavior [
	^ behavior
]

{ #category : #accessing }
TypeDiagnostic >> kind [
	^ kind
]

{ #category : #accessing }
TypeDiagnostic >> line [
	^ line
]

{ #category : #accessing }
TypeDiagnostic >> selector [
	^ selector
]

{ #category : #accessing }
TypeDiagnostic >> setBehavior: aBehavior selector: aSymbol [
	behavior := aBehavior.
	selector := aSymbol
]

{ #category : #accessing }
TypeDiagnostic >> setKind: aSymbol where: aString line: n text: t start: s end: e [
	kind := aSymbol.
	where := aString.
	line := n.
	text := t.
	sourceStart := s.
	sourceEnd := e
]

{ #category : #accessing }
TypeDiagnostic >> sourceEnd [
	^ sourceEnd
]

{ #category : #accessing }
TypeDiagnostic >> sourceStart [
	^ sourceStart
]

{ #category : #accessing }
TypeDiagnostic >> text [
	^ text
]

{ #category : #accessing }
TypeDiagnostic >> where [
	^ where
]

{ #category : #json }
TypeDiagnostic >> asJson [
	"The development protocol's form (the diagnostics request and the diagnostics.changed event): kind, class, side, selector, line, start, end (nil when the diagnostic has no node) and text."
	| o |
	o := JsonObject new.
	o at: 'kind' put: kind asString;
		at: 'class' put: (behavior ifNil: [where] ifNotNil: [:b | b theNonMetaClass name asString]);
		at: 'side' put: ((behavior notNil and: [behavior isMeta]) ifTrue: ['class'] ifFalse: ['instance']);
		at: 'selector' put: (selector ifNil: [nil] ifNotNil: [:s | s asString]);
		at: 'line' put: line;
		at: 'start' put: sourceStart;
		at: 'end' put: sourceEnd;
		at: 'text' put: text.
	^ o
]

{ #category : #printing }
TypeDiagnostic >> printOn: aStream [
	aStream nextPutAll: kind; nextPutAll: ' '; nextPutAll: where; nextPutAll: ':'; print: line; nextPutAll: ' '; nextPutAll: text
]

{ #category : #'instance creation' }
TypeDiagnostic class >> kind: aSymbol where: aString line: n text: t [
	^ self new setKind: aSymbol where: aString line: n text: t start: nil end: nil
]

{ #category : #'instance creation' }
TypeDiagnostic class >> kind: aSymbol where: aString line: n text: t start: s end: e [
	^ self new setKind: aSymbol where: aString line: n text: t start: s end: e
]
