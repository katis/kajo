"Objects larger than one heap block (module 10): an Array of 100 000 elements, a Set and a Dictionary of 50 000, an OrderedCollection past 4095, a String of a megabyte, the limit of the count field, and JSON still written in pieces for the transport."
Class {
	#name : #LargeObjectTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #tests }
LargeObjectTest >> testALargeArrayIsAnArray [
	| a b |
	a := Array new: 100000.
	self assert: a class equals: Array.
	self assert: a size equals: 100000.
	self assert: (a at: 100000) isNil.
	1 to: 100000 do: [:i | a at: i put: 100001 - i].
	self assert: (a at: 4096) equals: 95905.
	self assert: (a at: 100000) equals: 1.
	a sort: [:x :y | x <= y].
	self assert: (a at: 1) equals: 1.
	self assert: (a at: 100000) equals: 100000.
	b := a copy.
	b at: 1 put: #changed.
	self assert: (a at: 1) equals: 1.
	self should: [a at: 100001] raise: Error.
	self assert: (a inject: 0 into: [:s :x | s + x]) equals: 5000050000
]

{ #category : #tests }
LargeObjectTest >> testGrowableCollectionsPassOneBlock [
	| o s d |
	o := OrderedCollection new.
	1 to: 10000 do: [:i | o add: i].
	self assert: o size equals: 10000.
	self assert: o last equals: 10000.
	self assert: o asArray class equals: Array.
	self assert: o asArray size equals: 10000.
	self assert: (o collect: [:x | x * 2]) last equals: 20000.
	s := Set new.
	1 to: 50000 do: [:i | s add: i].
	self assert: s size equals: 50000.
	self assert: (s includes: 49999).
	d := IdentityDictionary new.
	1 to: 50000 do: [:i | d at: i put: i * i].
	self assert: (d at: 50000) equals: 2500000000.
	d removeKey: 50000.
	self assert: d size equals: 49999
]

{ #category : #tests }
LargeObjectTest >> testJsonInPieces [
	| o pieces back text |
	o := (1 to: 9000) asOrderedCollection collect: [:i | 'item ' , i printString].
	self assert: (Json write: o) byteSize > 32768.
	pieces := Json writePieces: o.
	self assert: pieces size > 2.
	self assert: (pieces allSatisfy: [:p | p size <= 16384]).
	text := (pieces collect: [:p | p asString]) asArray.
	back := Json read: text.
	self assert: back size equals: 9000.
	self assert: (back at: 9000) equals: 'item 9000'.
	self assert: (Json read: #('{"a":[1,' '2],"b":"x' 'y"}')) printString equals: '{"a":[1,2],"b":"xy"}'
]

{ #category : #tests }
LargeObjectTest >> testLargeStringsAndByteArrays [
	| s b |
	s := String new: 1000000 withAll: $a.
	self assert: s byteSize equals: 1000000.
	self assert: (s , 'b') byteSize equals: 1000001.
	self assert: ((s , 'b') copyFrom: 999999 to: 1000001) equals: 'aab'.
	b := ByteArray new: 100000.
	b at: 100000 put: 255.
	self assert: (b at: 100000) equals: 255
]

{ #category : #tests }
LargeObjectTest >> testNewPastTheLimitSignals [
	| e |
	e := [Array new: 16777216. nil] on: Error do: [:x | x messageText].
	self assert: (e includesSubstring: '16777215')
]
