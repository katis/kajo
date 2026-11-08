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

{ #category : #accessing }
StreamTest >> testWriteStreamPaths [
	"The collections-speed paths: one encoding send per Character, growth by copying in one step, nextPutAll: of a String, an Array or a ByteArray copied in one step, readLimit brought up to date where it is read."
	| w rw long b a |
	w := WriteStream on: String new.
	1 to: 40 do: [:i | w nextPut: $é; nextPut: $a].
	self assert: w contents = ((1 to: 40) inject: '' into: [:s :i | s , 'éa']).
	self assert: w position equals: 120.
	self should: [w nextPut: 7] raise: Error.
	self assert: w position equals: 120.
	long := String new: 1000 withAll: $x.
	w := WriteStream on: String new.
	w nextPut: $<; nextPutAll: long; nextPutAll: #sym; nextPutAll: ''; nextPut: $>.
	self assert: w contents byteSize equals: 1005.
	self assert: (w contents copyFrom: 1001 to: 1005) = 'xsym>'.
	w := WriteStream on: String new.
	w nextPutAll: 'abcdef'.
	w position: 2.
	w nextPut: $Z.
	self assert: w contents = 'abZ'.
	w position: 6.
	self assert: w contents = 'abZdef'.
	self should: [w position: 7] raise: Error.
	w reset.
	self deny: w atEnd.
	a := WriteStream on: (Array new: 0).
	a nextPut: 1; nextPut: 2; nextPut: 3.
	a reset.
	self deny: a atEnd.
	a skip: 3.
	self assert: a atEnd.
	rw := ReadWriteStream on: String new.
	rw nextPutAll: 'hello'.
	rw reset.
	rw nextPut: $j.
	self assert: rw contents = 'jello'.
	self assert: rw next == $e.
	a := WriteStream on: (Array new: 0).
	a nextPut: 1; nextPutAll: #(2 3); nextPutAll: (OrderedCollection with: 4 with: 5).
	1 to: 30 do: [:i | a nextPutAll: (Array with: i)].
	self assert: a contents size equals: 35.
	self assert: (a contents first: 5) = #(1 2 3 4 5).
	b := WriteStream on: (ByteArray new: 0).
	b nextPut: 1; nextPutAll: #[2 3]; nextPutAll: (ByteArray new: 40).
	self assert: b contents size equals: 43.
	self assert: (b contents first: 3) = #[1 2 3]
]
