"A method, a real block (a closure) or an inlined block; real ones lay out their frames. A copied value is a TempVariable or a CompilerScope (its temp vector)."
Class {
	#name : #CompilerScope,
	#superclass : #Object,
	#instVars : [
		'parent',
		'isReal',
		'seq',
		'declared',
		'locals',
		'needed',
		'copied',
		'vectorVariables',
		'vectorTemp',
		'argumentCount',
		'tempCount'
	],
	#category : #'Kernel-Compiler'
}

{ #category : #accessing }
CompilerScope class >> parent: aScope real: aBoolean seq: n [
	^ self new setParent: aScope real: aBoolean seq: n
]

{ #category : #accessing }
CompilerScope >> setParent: aScope real: aBoolean seq: n [
	parent := aScope.
	isReal := aBoolean.
	seq := n.
	declared := OrderedCollection new.
	locals := OrderedCollection new.
	needed := OrderedCollection new.
	copied := #().
	vectorVariables := #().
	vectorTemp := -1.
	argumentCount := 0.
	tempCount := 0
]

{ #category : #accessing }
CompilerScope >> parent [
	^ parent
]

{ #category : #accessing }
CompilerScope >> isReal [
	^ isReal
]

{ #category : #accessing }
CompilerScope >> seq [
	^ seq
]

{ #category : #accessing }
CompilerScope >> real [
	^ isReal ifTrue: [self] ifFalse: [parent real]
]

{ #category : #accessing }
CompilerScope >> declared [
	^ declared
]

{ #category : #accessing }
CompilerScope >> locals [
	^ locals
]

{ #category : #accessing }
CompilerScope >> needed [
	^ needed
]

{ #category : #accessing }
CompilerScope >> copied [
	^ copied
]

{ #category : #accessing }
CompilerScope >> vectorVariables [
	^ vectorVariables
]

{ #category : #accessing }
CompilerScope >> vectorTemp [
	^ vectorTemp
]

{ #category : #accessing }
CompilerScope >> argumentCount [
	^ argumentCount
]

{ #category : #accessing }
CompilerScope >> argumentCount: n [
	argumentCount := n
]

{ #category : #accessing }
CompilerScope >> tempCount [
	^ tempCount
]

{ #category : #accessing }
CompilerScope >> copiedIndex: anItem [
	^ argumentCount + (copied indexOf: anItem) - 1
]

{ #category : #accessing }
CompilerScope >> layout [
	"Frame indices once every reference is known (the rules in Sources/KajoCompiler/Compiler.swift)."
	| sorted items next i |
	sorted := locals asArray sort: [:a :b | a seq <= b seq].
	parent notNil ifTrue: [
		items := OrderedCollection new.
		needed do: [:v | | c |
			c := v inVector ifTrue: [v real] ifFalse: [v].
			(items identityIncludes: c) ifFalse: [items add: c]].
		copied := items asArray sort: [:a :b | a seq <= b seq]].
	next := argumentCount + copied size.
	i := 0.
	sorted do: [:v | v kind == #argument ifTrue: [v index: i. i := i + 1]].
	vectorVariables := sorted select: [:v | v inVector].
	vectorVariables doWithIndex: [:v :k | v vectorSlot: k - 1].
	vectorVariables isEmpty ifFalse: [vectorTemp := next. next := next + 1].
	sorted do: [:v | (v kind ~~ #argument and: [v inVector not]) ifTrue: [v index: next. next := next + 1]].
	tempCount := next - argumentCount - copied size
]
