"Types 1 (docs/modules/types-1.md) in the image: the kernel's compiler compiles a typed method to what it compiles with the types blanked (every typed method of the image), keeps the types in the tree, refuses a capitalized pragma; a typed class read from Tonel keeps its class-level types and writes them back; a redefinition that removes an instance variable takes its type with it."
Class {
	#name : #TypeSyntaxTest,
	#superclass : #TestCase
}

{ #category : #helpers }
TypeSyntaxTest >> blank: aString spans: spans [
	"aString with each type span, and a result's ^, replaced by blanks (line breaks kept): the same offsets, so the same source map."
	| out i |
	out := WriteStream on: String new.
	i := 1.
	spans do: [:sp | | a |
		a := sp first.
		(a > 0 and: [(aString byteAt: a) = 94]) ifTrue: [a := a - 1].
		out nextPutAll: (aString copyFrom: i to: a).
		a + 1 to: sp last do: [:k | out nextPut: ((aString byteAt: k) = 10 ifTrue: [Character lf] ifFalse: [$ ])].
		i := sp last + 1].
	out nextPutAll: (aString copyFrom: i to: aString byteSize).
	^ out contents
]

{ #category : #tests }
TypeSyntaxTest >> testACapitalizedPragmaIsRefused [
	#('f <Primitive: 60> ^ 1' 'f <Unwind> ^ 1' 'f | t | <Integer> ^ 1' 'f: x <Integer> ^<Integer> <Integer> ^ x') do: [:src |
		self should: [Compiler compile: src in: Object] raise: CompileError].
	self assert: (Compiler compile: 'f: x <unwind> ^ x' in: Object) notNil
]

{ #category : #tests }
TypeSyntaxTest >> testARedefinitionTakesARemovedVariablesTypeWithIt [
	| text cls |
	text := 'Class {
	#name : #TypeSyntaxProbe,
	#superclass : #Object,
	#typeParameters : [
		''E''
	],
	#instVars : [
		''a <Array[E]>'',
		''b <Integer>''
	]
}
'.
	cls := Smalltalk readTonel: text.
	[self assert: cls tonelSource equals: text.
	 self assert: ((Smalltalk typesOf: cls) typeOf: #a) equals: 'Array[E]'.
	 ClassBuilder define: 'TypeSyntaxProbe' superclass: Object instanceVariableNames: #('b' 'c') classVariableNames: #()
		classInstanceVariableNames: nil package: nil tag: nil kind: nil comment: nil.
	 self assert: ((Smalltalk typesOf: cls) typeOf: #a) isNil.
	 self assert: ((Smalltalk typesOf: cls) typeOf: #b) equals: 'Integer'.
	 self assert: (cls tonelSource includesSubstring: '''b <Integer>''').
	 self assert: (cls tonelSource includesSubstring: '''c''')]
		ensure: [Smalltalk removeClass: cls].
	self assert: (Smalltalk typesOf: cls) isNil.
	"The removed class is freed now, so its class index is free before the next test makes a class (DevelopmentTest>>testRemovedClassesAreFreedAndTheirIndicesTaken expects the index it frees to be the one taken)."
	cls := nil.
	Smalltalk garbageCollect
]

{ #category : #tests }
TypeSyntaxTest >> testAnAgentsMarkGoesAfterATypedPattern [
	"TonelWriter source:author: skips the pattern with its types, as the Parser reads it, before it puts the agent's mark in."
	| lf |
	lf := String lf.
	self assert: (TonelWriter source: 'at: i <Integer> put: v <[E, ^:X]> ^<E>' , lf , (String tab) , '^ v' author: 'agent:x')
		equals: 'at: i <Integer> put: v <[E, ^:X]> ^<E>' , lf , (String tab) , '<author: #''agent:x''>' , lf , (String tab) , '^ v'.
	self assert: (Scanner patternEndIn: 'at: i <Integer> put: v <[E, ^:X]> ^<E>' , lf , '^ v') equals: 38
]

{ #category : #tests }
TypeSyntaxTest >> testTheTreeKeepsTheTypes [
	| tree |
	tree := Parser parse: 'at: k <K> ifAbsent: aBlock <[^:X]> ^<V | X>
	^ nil'.
	self assert: tree argumentTypes first description equals: '(name K 7 8)'.
	self assert: (tree argumentTypes at: 2) kind equals: #block.
	self assert: (tree argumentTypes at: 2) result declaresVariable.
	self assert: tree resultType description equals: '(union 37 42 (name V 37 38) (name X 41 42))'.
	self assert: (Parser parse: 'size ^ 3') resultType isNil
]

{ #category : #tests }
TypeSyntaxTest >> testTypesCompileToNothing [
	"Starting position 4 in the kernel's compiler: every method of the image whose pattern holds a type compiles to the same code as its source with the types blanked (same offsets, so the same source map too)."
	<slow>
	| checked failures |
	checked := 0.
	failures := OrderedCollection new.
	Smalltalk allBehaviors do: [:c |
		c methodsDo: [:m | | src spans |
			src := Smalltalk sourceOf: m.
			spans := (Parser patternOf: src) typeSpans.
			spans isEmpty ifFalse: [ | d |
				d := (Compiler compile: src in: c) sameCodeAs: (Compiler compile: (self blank: src spans: spans) in: c).
				d ifNotNil: [:x | failures add: m printString , ': ' , x].
				checked := checked + 1]]].
	self assert: checked >= 577.
	self assert: failures isEmpty description: (failures isEmpty ifTrue: [''] ifFalse: [failures size printString , ' differ, the first: ' , failures first])
]
