"pragmas: Arrays of selector, arguments and line."
Class {
	#name : #MethodNode,
	#superclass : #ParseNode,
	#instVars : [
		'selector',
		'arguments',
		'temporaries',
		'pragmas',
		'statements'
	]
}

{ #category : #accessing }
MethodNode >> arguments [
	^ arguments
]

{ #category : #accessing }
MethodNode >> pragmas [
	^ pragmas
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
