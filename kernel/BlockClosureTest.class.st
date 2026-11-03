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
