Class {
	#name : #BooleanTest,
	#superclass : #TestCase
}

{ #category : #accessing }
BooleanTest >> testConditionalsWithNonLiteralBlocks [
	| t f |
	t := [1].
	f := [2].
	self assert: (true ifTrue: t ifFalse: f) = 1.
	self assert: (false ifTrue: t ifFalse: f) = 2.
	self assert: (false ifTrue: t) isNil.
	self assert: (true perform: #ifTrue: with: t) = 1
]

{ #category : #accessing }
BooleanTest >> testLogic [
	self assert: (true and: [true]).
	self deny: (true and: [false]).
	self assert: (false or: [true]).
	self assert: true & true.
	self deny: true & false.
	self assert: false | true.
	self assert: true not not.
	self assert: (true xor: false).
	self deny: (true xor: true)
]

{ #category : #accessing }
BooleanTest >> testPrinting [
	self assert: true printString = 'true'.
	self assert: false printString = 'false'
]
