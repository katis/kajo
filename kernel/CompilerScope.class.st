"A method, a real block (a closure) or an inlined block; real ones lay out their frames. A copied value is a TempVariable or a CompilerScope (its temp vector). An inlined loop body (isLoop) owns a temp vector of its own, made afresh on every pass (Pharo's rule; Sources/KajoCompiler/Compiler.swift)."
Class {
	#name : #CompilerScope,
	#superclass : #Object,
	#instVars : [
		'parent',
		'isReal',
		'isLoop',
		'seq',
		'declared',
		'locals',
		'needed',
		'copied',
		'loops',
		'vectorVariables',
		'vectorTemp',
		'argumentCount',
		'tempCount'
	],
	#category : #'Kernel-Compiler'
}

{ #category : #accessing }
CompilerScope >> argumentCount [
	^ argumentCount
]

{ #category : #accessing }
CompilerScope >> argumentCount: n [
	argumentCount := n
]

{ #category : #accessing }
CompilerScope >> beLoop [
	isLoop := true
]

{ #category : #accessing }
CompilerScope >> copied [
	^ copied
]

{ #category : #accessing }
CompilerScope >> copiedIndex: anItem [
	^ argumentCount + (copied indexOf: anItem) - 1
]

{ #category : #accessing }
CompilerScope >> declared [
	^ declared
]

{ #category : #accessing }
CompilerScope >> isLoop [
	^ isLoop
]

{ #category : #accessing }
CompilerScope >> isReal [
	^ isReal
]

{ #category : #accessing }
CompilerScope >> layout [
	"Frame indices once every reference is known (the rules in Sources/KajoCompiler/Compiler.swift)."
	| sorted items next i ordered |
	sorted := locals asArray sort: [:a :b | a seq <= b seq].
	parent notNil ifTrue: [
		items := OrderedCollection new.
		needed do: [:v | | c |
			c := v inVector ifTrue: [v owner] ifFalse: [v].
			(items identityIncludes: c) ifFalse: [items add: c]].
		copied := items asArray sort: [:a :b | a seq <= b seq]].
	next := argumentCount + copied size.
	i := 0.
	sorted do: [:v | v kind == #argument ifTrue: [v index: i. i := i + 1]].
	vectorVariables := sorted select: [:v | v inVector and: [v owner == self]].
	vectorVariables doWithIndex: [:v :k | v vectorSlot: k - 1].
	vectorVariables isEmpty ifFalse: [vectorTemp := next. next := next + 1].
	"The other locals and the loop bodies' vector temps, in sequence order."
	ordered := OrderedCollection new.
	sorted do: [:v | (v kind ~~ #argument and: [v inVector not]) ifTrue: [ordered add: v]].
	loops do: [:l |
		l takeVectorFrom: sorted.
		l vectorVariables isEmpty ifFalse: [ordered add: l]].
	(ordered asArray sort: [:a :b | a seq <= b seq]) do: [:x |
		(x isKindOf: CompilerScope) ifTrue: [x vectorTemp: next] ifFalse: [x index: next].
		next := next + 1].
	tempCount := next - argumentCount - copied size
]

{ #category : #accessing }
CompilerScope >> locals [
	^ locals
]

{ #category : #accessing }
CompilerScope >> loops [
	^ loops
]

{ #category : #accessing }
CompilerScope >> needed [
	^ needed
]

{ #category : #accessing }
CompilerScope >> owner [
	"The scope whose temp vector holds a captured and assigned variable declared here: this one if it is real or a loop body, else the enclosing one's."
	^ (isReal or: [isLoop]) ifTrue: [self] ifFalse: [parent owner]
]

{ #category : #accessing }
CompilerScope >> parent [
	^ parent
]

{ #category : #accessing }
CompilerScope >> real [
	^ isReal ifTrue: [self] ifFalse: [parent real]
]

{ #category : #accessing }
CompilerScope >> seq [
	^ seq
]

{ #category : #accessing }
CompilerScope >> setParent: aScope real: aBoolean seq: n [
	parent := aScope.
	isReal := aBoolean.
	isLoop := false.
	seq := n.
	declared := OrderedCollection new.
	locals := OrderedCollection new.
	needed := OrderedCollection new.
	copied := #().
	loops := OrderedCollection new.
	vectorVariables := #().
	vectorTemp := -1.
	argumentCount := 0.
	tempCount := 0
]

{ #category : #accessing }
CompilerScope >> takeVectorFrom: sortedLocals [
	"A loop body: its vector's variables, in sequence order."
	vectorVariables := sortedLocals select: [:v | v inVector and: [v owner == self]].
	vectorVariables doWithIndex: [:v :k | v vectorSlot: k - 1]
]

{ #category : #accessing }
CompilerScope >> tempCount [
	^ tempCount
]

{ #category : #accessing }
CompilerScope >> vectorTemp [
	^ vectorTemp
]

{ #category : #accessing }
CompilerScope >> vectorTemp: n [
	vectorTemp := n
]

{ #category : #accessing }
CompilerScope >> vectorVariables [
	^ vectorVariables
]

{ #category : #debugging }
CompilerScope >> frameVariables [
	"A real scope's named variables as a frame holds them (module 9b): {name. frame index from 1. index in the temp vector from 1, or nil}; a name declared twice (inlined blocks) keeps its last."
	| out add |
	out := OrderedCollection new.
	add := [:name :frame :slot |
		name isEmpty ifFalse: [
			out removeAll: (out select: [:e | e first = name]).
			out add: {name. frame. slot}]].
	(locals select: [:v | v kind == #argument]) do: [:v | add value: v name value: v index + 1 value: nil].
	copied do: [:item |
		(item isKindOf: CompilerScope)
			ifTrue: [item vectorVariables do: [:v | add value: v name value: (self copiedIndex: item) + 1 value: v vectorSlot + 1]]
			ifFalse: [add value: item name value: (self copiedIndex: item) + 1 value: nil]].
	vectorTemp >= 0 ifTrue: [vectorVariables do: [:v | add value: v name value: vectorTemp + 1 value: v vectorSlot + 1]].
	loops do: [:l | l vectorTemp >= 0 ifTrue: [l vectorVariables do: [:v | add value: v name value: l vectorTemp + 1 value: v vectorSlot + 1]]].
	(locals select: [:v | v kind ~~ #argument and: [v kind ~~ #hidden and: [v inVector not]]]) do: [:v |
		add value: v name value: v index + 1 value: nil].
	^ out asArray
]

{ #category : #accessing }
CompilerScope class >> loopIn: aScope seq: n [
	^ (self new setParent: aScope real: false seq: n) beLoop
]

{ #category : #accessing }
CompilerScope class >> parent: aScope real: aBoolean seq: n [
	^ self new setParent: aScope real: aBoolean seq: n
]
