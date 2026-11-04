"Closures: copied values, temp vectors, non-local return, numArgs, cull:, cannotReturn:."
Class {
	#name : #BlockClosureTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
BlockClosureTest >> testValues [
	self assert: [3] value = 3.
	self assert: ([:x | x + 1] value: 3) = 4.
	self assert: ([:x :y | x * y] value: 3 value: 4) = 12.
	self assert: ([:a :b :c | a + b + c] value: 1 value: 2 value: 3) = 6.
	self assert: ([:a :b | a - b] valueWithArguments: #(5 3)) = 2.
	self assert: [:a :b | a] numArgs = 2.
	self assert: ([:x | x] cull: 7) = 7.
	self assert: ([7] cull: 3) = 7.
	self should: [[:x | x] value] raise: Error
]

{ #category : #accessing }
BlockClosureTest >> testCapturesShareTheirVariables [
	| counter inc get |
	counter := 0.
	inc := [counter := counter + 1].
	get := [counter].
	inc value; value.
	self assert: get value = 2.
	self assert: counter = 2
]

{ #category : #accessing }
BlockClosureTest >> testEachClosureHasItsOwnCopies [
	| blocks |
	blocks := (1 to: 3) collect: [:i | [i * 10]].
	self assert: (blocks collect: [:b | b value]) = #(10 20 30)
]

{ #category : #accessing }
BlockClosureTest >> testNestedBlocks [
	| adder |
	adder := [:x | [:y | [:z | x + y + z]]].
	self assert: (((adder value: 1) value: 2) value: 3) = 6
]

{ #category : #accessing }
BlockClosureTest >> testNonLocalReturn [
	self assert: (self findFirstEven: #(1 3 4 5 6)) = 4.
	self assert: (self findFirstEven: #(1 3)) isNil
]

{ #category : #accessing }
BlockClosureTest >> findFirstEven: aCollection [
	aCollection do: [:x | x even ifTrue: [^ x]].
	^ nil
]

{ #category : #accessing }
BlockClosureTest >> testCannotReturn [
	| b r |
	b := self makeEscapingBlock.
	r := [b value] on: BlockCannotReturn do: [:e | e result].
	self assert: r = 99
]

{ #category : #accessing }
BlockClosureTest >> makeEscapingBlock [
	^ [^ 99]
]

{ #category : #accessing }
BlockClosureTest >> testWhileLoopsWithNonLiteralBlocks [
	| i cond body |
	i := 0.
	cond := [i < 5].
	body := [i := i + 1].
	cond whileTrue: body.
	self assert: i = 5
]

{ #category : #accessing }
BlockClosureTest >> testThisContext [
	| ctx |
	ctx := thisContext.
	self assert: ctx method selector == #testThisContext.
	self assert: ctx receiver == self.
	self assert: ctx sender notNil.
	self deny: ctx isDead
]

{ #category : #tests }
BlockClosureTest >> testLoopBodyTempsArePerIteration [
	"Module 8d, Pharo's rule: a temp declared in an inlined loop body, captured and assigned, is a fresh variable on every pass."
	| blocks k |
	blocks := OrderedCollection new.
	1 to: 3 do: [:i | | t | t := i * 10. blocks add: [t := t + 1]].
	self assert: (blocks collect: [:b | b value]) asArray = #(11 21 31).
	self assert: (blocks collect: [:b | b value]) asArray = #(12 22 32).
	blocks := OrderedCollection new.
	k := 0.
	[k < 3] whileTrue: [| t | k := k + 1. t := k. blocks add: [t := t * 2]].
	self assert: (blocks collect: [:b | b value]) asArray = #(2 4 6).
	blocks := OrderedCollection new.
	k := 0.
	3 timesRepeat: [| t | k := k + 1. t := k. k > 0 ifTrue: [| u | u := t + 100. blocks add: [u := u + t]]].
	self assert: (blocks collect: [:b | b value]) asArray = #(102 104 106)
]

{ #category : #tests }
BlockClosureTest >> testLoopTempsSharedByTheBodysProcesses [
	"Forked blocks from successive iterations each assign their own body temp and answer it."
	| q results |
	q := SharedQueue new.
	1 to: 8 do: [:i | | t | t := i. [t := t * t. q nextPut: t] fork].
	results := Set new.
	8 timesRepeat: [results add: q next].
	self assert: results = (#(1 4 9 16 25 36 49 64) asSet)
]
