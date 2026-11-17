"pragmas: Arrays of selector, arguments and line. Types 1: argumentTypes, a TypeNode or nil per argument, and resultType, as written in the pattern; code generation reads neither."
Class {
	#name : #MethodNode,
	#superclass : #ParseNode,
	#instVars : [
		'selector',
		'arguments',
		'temporaries',
		'pragmas',
		'statements',
		'argumentTypes',
		'resultType'
	]
}

{ #category : #accessing }
MethodNode >> argumentTypes [
	^ argumentTypes ifNil: [#()]
]

{ #category : #accessing }
MethodNode >> argumentTypes: anArray resultType: aTypeNodeOrNil [
	argumentTypes := anArray.
	resultType := aTypeNodeOrNil
]

{ #category : #accessing }
MethodNode >> arguments [
	^ arguments
]

{ #category : #accessing }
MethodNode >> pragmas [
	^ pragmas
]

{ #category : #accessing }
MethodNode >> resultType [
	^ resultType
]

{ #category : #accessing }
MethodNode >> selector [
	^ selector
]

{ #category : #accessing }
MethodNode >> setSelector: s arguments: a temporaries: t pragmas: p statements: st [
	selector := s.
	arguments := a.
	temporaries := t.
	pragmas := p.
	statements := st
]

{ #category : #accessing }
MethodNode >> statements [
	^ statements
]

{ #category : #accessing }
MethodNode >> temporaries [
	^ temporaries
]

{ #category : #accessing }
MethodNode >> typesDescription [
	"The types as both compilers' tests compare them (the bootstrap's MethodNode.typesDescription): one line per argument (- when untyped), then the result."
	| s |
	s := WriteStream on: String new.
	self argumentTypes do: [:t | t isNil ifTrue: [s nextPutAll: '-'] ifFalse: [t printDescriptionOn: s]. s nextPut: Character lf].
	resultType isNil ifTrue: [s nextPutAll: '-'] ifFalse: [resultType printDescriptionOn: s].
	^ s contents
]
