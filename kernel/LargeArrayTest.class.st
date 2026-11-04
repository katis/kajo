"Collections longer than one object can be (module 9c): an OrderedCollection, a Set and a Dictionary past 4095 entries, their Arrays, and JSON written and read in pieces."
Class {
	#name : #LargeArrayTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #tests }
LargeArrayTest >> testALargeArrayIsASequence [
	| a b |
	self assert: (Array large: 10) class equals: Array.
	a := Array large: 5000.
	self assert: a class equals: LargeArray.
	self assert: a size equals: 5000.
	1 to: 5000 do: [:i | a at: i put: 5001 - i].
	self assert: (a at: 2048) equals: 2953.
	self assert: (a at: 2049) equals: 2952.
	a sort: [:x :y | x <= y].
	self assert: (a at: 1) equals: 1.
	self assert: (a at: 5000) equals: 5000.
	b := a copy.
	b at: 1 put: #changed.
	self assert: (a at: 1) equals: 1.
	self should: [a at: 5001] raise: Error.
	self assert: (a inject: 0 into: [:s :x | s + x]) equals: 12502500
]

{ #category : #tests }
LargeArrayTest >> testGrowableCollectionsPassOneObject [
	| o s d |
	o := OrderedCollection new.
	1 to: 10000 do: [:i | o add: i].
	self assert: o size equals: 10000.
	self assert: o last equals: 10000.
	self assert: o asArray size equals: 10000.
	self assert: (o collect: [:x | x * 2]) last equals: 20000.
	s := Set new.
	1 to: 6000 do: [:i | s add: i printString].
	self assert: s size equals: 6000.
	self assert: (s includes: '5999').
	d := IdentityDictionary new.
	1 to: 6000 do: [:i | d at: i put: i * i].
	self assert: (d at: 5000) equals: 25000000.
	d removeKey: 5000.
	self assert: d size equals: 5999
]

{ #category : #tests }
LargeArrayTest >> testJsonInPieces [
	| o pieces back text |
	o := (1 to: 9000) asOrderedCollection collect: [:i | 'item ' , i printString].
	pieces := Json writePieces: o.
	self assert: pieces size > 2.
	self assert: (pieces allSatisfy: [:p | p size <= 16384]).
	text := (pieces collect: [:p | p asString]) asArray.
	back := Json read: text.
	self assert: back size equals: 9000.
	self assert: (back at: 9000) equals: 'item 9000'.
	self assert: (Json read: #('{"a":[1,' '2],"b":"x' 'y"}')) printString equals: '{"a":[1,2],"b":"xy"}'
]
