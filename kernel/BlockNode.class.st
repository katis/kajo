"arguments and temporaries: Arrays of name and line."
Class {
	#name : #BlockNode,
	#superclass : #ParseNode,
	#instVars : [
		'arguments',
		'temporaries',
		'statements',
		'scope'
	],
	#category : #'Kernel-Compiler'
}

{ #category : #accessing }
BlockNode class >> arguments: a temporaries: t statements: s line: n [
	^ self new setArguments: a temporaries: t statements: s; line: n; yourself
]

{ #category : #accessing }
BlockNode >> setArguments: a temporaries: t statements: s [
	arguments := a.
	temporaries := t.
	statements := s
]

{ #category : #accessing }
BlockNode >> arguments [
	^ arguments
]

{ #category : #accessing }
BlockNode >> temporaries [
	^ temporaries
]

{ #category : #accessing }
BlockNode >> statements [
	^ statements
]

{ #category : #accessing }
BlockNode >> scope [
	^ scope
]

{ #category : #accessing }
BlockNode >> scope: aScope [
	scope := aScope
]

{ #category : #accessing }
BlockNode >> numArgs [
	^ arguments size
]
