"The index-free String: scalars, byte offsets at boundaries, immutability, the protocol kernel.md lists."
Class {
	#name : #StringTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
StringTest >> testScalarsAndBytes [
	| s |
	s := 'añ😀'.
	self assert: s scalarCount = 3.
	self assert: s utf8Size = 7.
	self assert: s utf8 size = 7.
	self assert: (s utf8 at: 1) = 97.
	self assert: (s scalarAt: 1) == $a.
	self assert: (s scalarAt: 2) value = 16rF1.
	self assert: (s scalarAt: 4) value = 16r1F600.
	self assert: (s isBoundary: 4).
	self deny: (s isBoundary: 3).
	self should: [s scalarAt: 3] raise: SubscriptOutOfBounds.
	self assert: s asArray size = 3
]

{ #category : #accessing }
StringTest >> testNoSizeNoIndexNoMutation [
	self should: ['abc' size] raise: Error.
	self should: ['abc' at: 1] raise: Error.
	self should: ['abc' at: 1 put: $x] raise: Error
]

{ #category : #accessing }
StringTest >> testIteration [
	| out |
	out := OrderedCollection new.
	'añb' do: [:c | out add: c].
	self assert: out asArray = {$a. Character value: 16rF1. $b}.
	out := OrderedCollection new.
	'añb' reverseDo: [:c | out add: c].
	self assert: out first == $b.
	self assert: ('hello' collect: [:c | c asUppercase]) = 'HELLO'.
	self assert: ('hello' select: [:c | c isVowel]) = 'eo'.
	self assert: ('hello' detect: [:c | c isVowel]) == $e.
	self assert: ('hello' includes: $l).
	self assert: ('hello' occurrencesOf: $l) = 2.
	self assert: 'héllo' reversed = 'olléh'
]

{ #category : #accessing }
StringTest >> testCopyingAndSearching [
	| s |
	s := 'hello world'.
	self assert: (s copyFrom: 1 to: 5) = 'hello'.
	self assert: (s indexOf: $o) = 5.
	self assert: (s indexOfSubstring: 'world') = 7.
	self assert: (s includesSubstring: 'lo w').
	self assert: (s beginsWith: 'hell').
	self assert: (s endsWith: 'world').
	self deny: (s endsWith: 'worlds').
	self assert: 'añb' first == $a.
	self assert: 'añb' last == $b.
	self assert: ('añb' first: 2) = 'añ'.
	self assert: 'añb' allButFirst = 'ñb'.
	self should: ['añ' copyFrom: 1 to: 2] raise: SubscriptOutOfBounds
]

{ #category : #accessing }
StringTest >> testConcatenationAndComparison [
	self assert: 'abc' , 'def' = 'abcdef'.
	self assert: 'abc' < 'abd'.
	self assert: 'abc' < 'abcd'.
	self assert: 'b' > 'a'.
	self assert: 'é' > 'z'.
	self assert: 'abc' = 'abc'.
	self deny: 'abc' = 'abd'.
	self assert: 'abc' hash = 'abc' hash.
	self deny: 'abc' = #abc
]

{ #category : #accessing }
StringTest >> testProtocol [
	self assert: 'Hello' asUppercase = 'HELLO'.
	self assert: 'Hello' asLowercase = 'hello'.
	self assert: '  hi there  ' trimmed = 'hi there'.
	self assert: ('a,b,,c' splitOn: ',') = #('a' 'b' '' 'c').
	self assert: ('one two' splitOn: $ ) = #('one' 'two').
	self assert: ('a-b-c' replaceAll: '-' with: '+') = 'a+b+c'.
	self assert: ('abab' replaceAll: 'ab' with: 'x') = 'xx'.
	self assert: ('line1' , String lf , 'line2') lines = #('line1' 'line2').
	self assert: ('a' , String cr , String lf , 'b' , String lf) lines = #('a' 'b').
	self assert: '  a  b ' substrings = #('a' 'b').
	self assert: '42' asNumber = 42.
	self assert: '2.5' asNumber = 2.5.
	self assert: 'abc' isString.
	self assert: '' isEmpty.
	self assert: 'a' notEmpty
]

{ #category : #accessing }
StringTest >> testPrinting [
	self assert: 'it''s' printString = '''it''''s'''.
	self assert: 'abc' displayString = 'abc'.
	self assert: 'abc' printString = '''abc'''
]

{ #category : #accessing }
StringTest >> testBuildingWithStreams [
	| s |
	s := WriteStream on: String new.
	s nextPutAll: 'ab'; nextPut: (Character value: 16r1F600); print: 42; space; nextPutAll: 'ñ'.
	self assert: s contents = 'ab😀42 ñ'.
	self assert: (String new: 3 withAll: $z) = 'zzz'.
	self assert: (String with: $a with: $b) = 'ab'.
	self assert: (String streamContents: [:w | w nextPutAll: 'x'; print: 1]) = 'x1'
]

{ #category : #accessing }
StringTest >> testInvalidBytes [
	| b |
	b := ByteArray new: 2.
	b at: 1 put: 16rC3; at: 2 put: 16r28.
	self should: [b asStringValidating] raise: Error.
	self assert: b asStringRepairing scalarCount = 2.
	b at: 2 put: 16rA9.
	self assert: b asString = 'é'
]

{ #category : #accessing }
StringTest >> testLiteralsAreReadOnly [
	self assert: 'abc' isReadOnly.
	self assert: #(1 2) isReadOnly.
	self should: [#(1 2) at: 1 put: 3] raise: ModificationForbidden
]
