"One finding of the checker. kind: #dnu (the receiver's type does not understand the selector), #maybeNil (a send to a type that includes Nil, which does not understand it), #argType (an argument is not of the parameter's type), #arity (a block literal with the wrong number of arguments), #blockResult (a block literal answers the wrong type), #returnType, #assignType, #annotation (a side file's line is wrong) and #parse (a method's source does not parse). Never a refusal: a list."
Class {
	#name : #OTDiagnostic,
	#superclass : #Object,
	#instVars : [
		'kind',
		'where',
		'line',
		'text',
		'sourceStart',
		'sourceEnd'
	]
}

{ #category : #accessing }
OTDiagnostic >> kind [
	^ kind
]

{ #category : #accessing }
OTDiagnostic >> line [
	^ line
]

{ #category : #printing }
OTDiagnostic >> printOn: aStream [
	aStream nextPutAll: kind; nextPutAll: ' '; nextPutAll: where; nextPutAll: ':'; print: line; nextPutAll: ' '; nextPutAll: text
]

{ #category : #accessing }
OTDiagnostic >> setKind: aSymbol where: aString line: n text: t start: s end: e [
	kind := aSymbol.
	where := aString.
	line := n.
	text := t.
	sourceStart := s.
	sourceEnd := e
]

{ #category : #accessing }
OTDiagnostic >> sourceEnd [
	^ sourceEnd
]

{ #category : #accessing }
OTDiagnostic >> sourceStart [
	^ sourceStart
]

{ #category : #accessing }
OTDiagnostic >> text [
	^ text
]

{ #category : #accessing }
OTDiagnostic >> where [
	^ where
]

{ #category : #'instance creation' }
OTDiagnostic class >> kind: aSymbol where: aString line: n text: t [
	^ self new setKind: aSymbol where: aString line: n text: t start: nil end: nil
]

{ #category : #'instance creation' }
OTDiagnostic class >> kind: aSymbol where: aString line: n text: t start: s end: e [
	^ self new setKind: aSymbol where: aString line: n text: t start: s end: e
]
