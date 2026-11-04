"Streams over collections and Strings (positions are byte offsets over a String)."
Class {
	#name : #StreamTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
StreamTest >> testReadStreamOnArray [
	| r |
	r := ReadStream on: #(1 2 3 4).
	self assert: r next = 1.
	self assert: r peek = 2.
	self assert: (r next: 2) = #(2 3).
	self deny: r atEnd.
	self assert: r upToEnd = #(4).
	self assert: r atEnd.
	self assert: r next isNil
]

{ #category : #accessing }
StreamTest >> testReadStreamOnString [
	| r |
	r := 'añb c' readStream.
	self assert: r next == $a.
	self assert: r position = 1.
	self assert: r next value = 16rF1.
	self assert: r position = 3.
	self assert: (r upTo: $ ) = 'b'.
	self assert: r upToEnd = 'c'.
	r reset.
	r skip: 2.
	self assert: r next == $b.
	self should: [r position: 2] raise: Error
]

{ #category : #accessing }
StreamTest >> testReadWriteStream [
	| rw |
	rw := ReadWriteStream on: String new.
	rw nextPutAll: 'héllo'.
	rw reset.
	self assert: rw next == $h.
	self assert: rw next value = 16rE9.
	self assert: rw contents = 'héllo'.
	rw := ReadWriteStream on: (Array new: 0).
	rw nextPut: 1; nextPut: 2.
	rw reset.
	self assert: rw next = 1.
	self assert: rw contents = #(1 2)
]

{ #category : #accessing }
StreamTest >> testWriteStreamOnArray [
	| w |
	w := WriteStream on: (Array new: 0).
	1 to: 20 do: [:i | w nextPut: i].
	self assert: w contents size = 20.
	self assert: w contents last = 20
]

{ #category : #accessing }
StreamTest >> testWriteStreamOnString [
	| w |
	w := WriteStream on: String new.
	1 to: 100 do: [:i | w print: i; space].
	self assert: (w contents beginsWith: '1 2 3').
	self assert: (w contents endsWith: '100 ').
	w := WriteStream on: String new.
	w << 'x = ' << 42.
	self assert: w contents = 'x = 42'
]
