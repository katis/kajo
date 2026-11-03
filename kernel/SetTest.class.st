Class {
	#name : #SetTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
SetTest >> testSet [
	| s |
	s := Set new.
	s add: 1; add: 2; add: 2; add: 'a'; add: 'a' copy.
	self assert: s size = 3.
	self assert: (s includes: 'a').
	self deny: (s includes: 3).
	s remove: 2.
	self assert: s size = 2.
	self should: [s remove: 9] raise: NotFound.
	1 to: 200 do: [:i | s add: i].
	self assert: s size = 201.
	1 to: 200 do: [:i | s remove: i].
	self assert: s size = 1.
	self assert: (s includes: 'a')
]

{ #category : #accessing }
SetTest >> testIdentitySet [
	| s a |
	s := IdentitySet new.
	a := 'abc' copy , ''.
	s add: a; add: a; add: 'abc' , ''.
	self assert: s size = 2.
	self assert: (s includes: a)
]

{ #category : #accessing }
SetTest >> testConversions [
	self assert: #(1 2 2 3) asSet size = 3.
	self assert: (#(1 2 3) asSet collect: [:x | x \\ 2]) size = 2.
	self assert: #(1 2) asSet = #(2 1) asSet
]
