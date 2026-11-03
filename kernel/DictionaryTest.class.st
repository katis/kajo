Class {
	#name : #DictionaryTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
DictionaryTest >> testAccess [
	| d |
	d := Dictionary new.
	d at: #a put: 1; at: 'b' put: 2; at: 3 put: 'three'.
	self assert: (d at: #a) = 1.
	self assert: (d at: 'b' copy) = 2.
	self assert: (d at: 3) = 'three'.
	self assert: d size = 3.
	self assert: (d at: #zz ifAbsent: [0]) = 0.
	self should: [d at: #zz] raise: KeyNotFound.
	self assert: (d at: #c ifAbsentPut: [9]) = 9.
	self assert: (d includesKey: #c).
	self assert: (d removeKey: #c) = 9.
	self deny: (d includesKey: #c).
	self assert: (d keyAtValue: 2) = 'b'.
	self assert: (d at: #a ifPresent: [:v | v + 1]) = 2
]

{ #category : #accessing }
DictionaryTest >> testGrowthAndRemoval [
	| d |
	d := Dictionary new.
	1 to: 300 do: [:i | d at: i put: i * i].
	self assert: d size = 300.
	self assert: (d at: 17) = 289.
	1 to: 300 by: 2 do: [:i | d removeKey: i].
	self assert: d size = 150.
	self assert: (d at: 18) = 324.
	self assert: (d at: 17 ifAbsent: [nil]) isNil.
	self assert: (d keys inject: 0 into: [:a :b | a + b]) = (2 to: 300 by: 2) sum
]

{ #category : #accessing }
DictionaryTest >> testEnumeration [
	| d sum |
	d := Dictionary new.
	d at: 1 put: 10; at: 2 put: 20.
	sum := 0.
	d keysAndValuesDo: [:k :v | sum := sum + k + v].
	self assert: sum = 33.
	self assert: (d collect: [:v | v * 2]) = (Dictionary new at: 1 put: 20; at: 2 put: 40; yourself).
	self assert: (d select: [:v | v > 15]) size = 1.
	self assert: d values asSet = #(10 20) asSet
]

{ #category : #accessing }
DictionaryTest >> testIdentityDictionary [
	| d k |
	d := IdentityDictionary new.
	k := 'key' , ''.
	d at: k put: 1.
	self assert: (d at: k) = 1.
	self assert: (d at: 'key' , '' ifAbsent: [0]) = 0
]
