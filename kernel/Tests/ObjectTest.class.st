"Object: identity, equality, copying, printing, perform:, instVarAt:, doesNotUnderstand:."
Class {
	#name : #ObjectTest,
	#superclass : #TestCase
}

{ #category : #accessing }
ObjectTest >> testClassMembership [
	self assert: 3 class == SmallInteger.
	self assert: (3 isKindOf: Integer).
	self assert: (3 isKindOf: Magnitude).
	self deny: (3 isKindOf: String).
	self assert: (3 isMemberOf: SmallInteger).
	self assert: (3 respondsTo: #printString).
	self deny: (3 respondsTo: #fooBar)
]

{ #category : #accessing }
ObjectTest >> testCopy [
	| a b |
	a := OrderedCollection new add: 1; yourself.
	b := a copy.
	b add: 2.
	self assert: a size = 1.
	self assert: b size = 2
]

{ #category : #accessing }
ObjectTest >> testDoesNotUnderstand [
	| r |
	r := [3 fooBar: 4] on: MessageNotUnderstood do: [:e |
		self assert: e message selector == #fooBar:.
		self assert: e message arguments = #(4).
		self assert: e receiver = 3.
		e return: 42].
	self assert: r = 42.
	r := [3 fooBar] on: MessageNotUnderstood do: [:e | e resume: 7].
	self assert: r = 7
]

{ #category : #accessing }
ObjectTest >> testIdentityAndEquality [
	| a |
	a := Object new.
	self assert: a == a.
	self assert: a = a.
	self deny: a = Object new.
	self assert: a ~~ Object new.
	self assert: a hash = a identityHash.
	self assert: 3 ~= 4
]

{ #category : #accessing }
ObjectTest >> testInstVarAt [
	| a |
	a := 3 -> 4.
	self assert: (a instVarAt: 1) = 3.
	a instVarAt: 2 put: 5.
	self assert: a value = 5
]

{ #category : #accessing }
ObjectTest >> testNilHandling [
	self assert: (nil ifNil: [1]) = 1.
	self assert: (3 ifNil: [1]) = 3.
	self assert: (3 ifNotNil: [:x | x + 1]) = 4.
	self assert: (nil ifNotNil: [:x | x + 1]) isNil.
	self assert: nil isNil.
	self deny: 3 isNil.
	self assert: (nil ifNil: [1] ifNotNil: [:x | 2]) = 1
]

{ #category : #accessing }
ObjectTest >> testPerform [
	self assert: (3 perform: #+ with: 4) = 7.
	self assert: (3 perform: #factorial) = 6.
	self assert: (3 perform: #between:and: withArguments: #(1 5)).
	self assert: (Array perform: #with:with: with: 1 with: 2) = #(1 2)
]

{ #category : #accessing }
ObjectTest >> testPrinting [
	self assert: Object new printString = 'an Object'.
	self assert: nil printString = 'nil'.
	self assert: true printString = 'true'.
	self assert: (3 -> 4) printString = '3->4'.
	self assert: #(1 $a 'b' #c) printString = '#(1 $a ''b'' #c)'
]

{ #category : #accessing }
ObjectTest >> testYourselfAndIn [
	self assert: (3 in: [:x | x * 2]) = 6.
	self assert: 3 yourself = 3
]
