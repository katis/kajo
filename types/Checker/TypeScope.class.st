"The variables of one scope of a method being checked (the method's, then one per block) with their current types, and the narrowings a nil test made in this scope (name to type, instance variables included). depth is the block nesting: an assignment from a deeper scope joins the old type, one at the variable's own depth replaces it (flow-sensitive in text order, loops not iterated)."
Class {
	#name : #TypeScope,
	#superclass : #Object,
	#instVars : [
		'parent',
		'vars',
		'narrowed',
		'kinds',
		'depth'
	]
}

{ #category : #accessing }
TypeScope >> declare: aName type: aType [
	vars at: aName put: aType
]

{ #category : #accessing }
TypeScope >> depth [
	^ depth
]

{ #category : #accessing }
TypeScope >> envDeclaring: aName [
	| e |
	e := self.
	[e notNil] whileTrue: [
		(e vars includesKey: aName) ifTrue: [^ e].
		e := e parent].
	^ nil
]

{ #category : #accessing }
TypeScope >> forgetNarrowing: aName [
	| e |
	e := self.
	[e notNil] whileTrue: [
		e narrowed removeKey: aName ifAbsent: [nil].
		e := e parent]
]

{ #category : #accessing }
TypeScope >> join: aName with: aType by: aChecker [
	"An assignment in this scope: each narrowing of aName in an enclosing scope below the variable's own now also holds aType."
	| e |
	e := self.
	[e notNil and: [(e vars includesKey: aName) not]] whileTrue: [
		(e narrowed at: aName ifAbsent: [nil]) ifNotNil: [:t | e narrowed at: aName put: (aChecker join: t with: aType)].
		e := e parent]
]

{ #category : #accessing }
TypeScope >> kinds [
	^ kinds
]

{ #category : #accessing }
TypeScope >> narrow: aName to: aType [
	narrowed at: aName put: aType
]

{ #category : #accessing }
TypeScope >> narrow: aName to: aType kind: aSymbol [
	"A narrowing that says how it was made (#nilFlow, #typeTest), for the counts of question 1."
	narrowed at: aName put: aType.
	kinds at: aName put: aSymbol
]

{ #category : #accessing }
TypeScope >> narrowed [
	^ narrowed
]

{ #category : #accessing }
TypeScope >> narrowingKindOf: aName [
	| e |
	e := self.
	[e notNil] whileTrue: [
		(e narrowed includesKey: aName) ifTrue: [^ e kinds at: aName ifAbsent: [#assignment]].
		(e vars includesKey: aName) ifTrue: [^ nil].
		e := e parent].
	^ nil
]

{ #category : #accessing }
TypeScope >> narrowingOf: aName [
	| e |
	e := self.
	[e notNil] whileTrue: [
		(e narrowed at: aName ifAbsent: [nil]) ifNotNil: [:t | ^ t].
		(e vars includesKey: aName) ifTrue: [^ nil].
		e := e parent].
	^ nil
]

{ #category : #accessing }
TypeScope >> parent [
	^ parent
]

{ #category : #accessing }
TypeScope >> setParent: anEnv depth: n [
	parent := anEnv.
	depth := n.
	vars := Dictionary new.
	narrowed := Dictionary new.
	kinds := Dictionary new
]

{ #category : #accessing }
TypeScope >> vars [
	^ vars
]

{ #category : #'instance creation' }
TypeScope class >> parent: anEnv [
	^ self new setParent: anEnv depth: (anEnv isNil ifTrue: [0] ifFalse: [anEnv depth + 1])
]
