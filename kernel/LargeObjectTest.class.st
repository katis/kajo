"Objects larger than one heap block (module 10): an Array of 100 000 elements, a Set and a Dictionary of 50 000, an OrderedCollection past 4095, a String of a megabyte, the limit of the count field, and JSON still written in pieces for the transport. Large bytes: a ByteArray and a String past the header's count field (16 MiB), and the byte objects' own limit."
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
LargeObjectTest >> testByteArraysPastTheCountField [
	"Large bytes: a ByteArray past 16 MiB, its length beyond what the header's count field holds: indexed, copied in part and whole, compared out of range."
	| b c n |
	n := 16777216 + 1003.
	b := ByteArray new: n.
	self assert: b size equals: n.
	self assert: (b at: n) equals: 0.
	b at: n put: 7; at: 16777209 put: 9; at: 1 put: 1.
	self assert: (b at: n) equals: 7.
	self assert: (b at: 16777209) equals: 9.
	self assert: (b at: 1) equals: 1.
	c := b copyFrom: 16777200 to: n.
	self assert: c size equals: n - 16777199.
	self assert: (c at: c size) equals: 7.
	self assert: (c at: 10) equals: 9.
	c := b copy.
	self assert: c size equals: n.
	self assert: (c at: n) equals: 7.
	self should: [b at: n + 1] raise: Error
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
	self assert: (e includesSubstring: '16777215').
	e := [ByteArray new: 2147483648. nil] on: Error do: [:x | x messageText].
	self assert: (e includesSubstring: '2147483647')
]

{ #category : #tests }
LargeObjectTest >> testStringsPastTheCountField [
	"Large bytes: a String past 16 MiB, concatenated, cut, compared and hashed."
	| s t |
	s := (ByteArray new: 16777300) asString.
	self assert: s byteSize equals: 16777300.
	t := s , 'b'.
	self assert: t byteSize equals: 16777301.
	self assert: (t copyFrom: 16777300 to: 16777301) byteSize equals: 2.
	self assert: s = s copy.
	self deny: s = t.
	self assert: s hash equals: s copy hash
]
