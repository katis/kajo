"ByteArray's equality and hash (the collections-speed module): primitives 121 and 122 over any byte object, the class check kept, the Smalltalk fallbacks agreeing with the primitives."
Class {
	#name : #ByteArrayTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #tests }
ByteArrayTest >> testEquality [
	| a b |
	a := ByteArray new: 3.
	a at: 1 put: 1; at: 2 put: 2; at: 3 put: 255.
	b := a copy.
	self assert: a = b.
	self assert: b = a.
	self assert: a = a.
	b at: 3 put: 254.
	self deny: a = b.
	self deny: #[1 2] = #[1 2 3].
	self deny: #[1 2 3] = #[1 2].
	self assert: #[] = (ByteArray new: 0).
	self deny: #[] = #[0].
	self deny: #[1 2 3] = #(1 2 3).
	self deny: #(1 2 3) = #[1 2 3].
	self deny: #[1 2 3] = nil.
	self deny: #[1 2 3] = 3
]

{ #category : #tests }
ByteArrayTest >> testHash [
	| a |
	a := #[1 2 3] copy.
	self assert: a hash equals: #[1 2 3] hash.
	self deny: #[1 2 3] hash = #[3 2 1] hash.
	(Array with: #[] with: #[0] with: #[255] with: #[200 100 0 255 7]) do: [:b |
		self assert: b hash equals: b hashOfBytes.
		self assert: b hash class equals: SmallInteger].
	self assert: #[97 98] hash equals: 'ab' hash
]

{ #category : #tests }
ByteArrayTest >> testKeysInHashedCollections [
	| d s |
	d := Dictionary new.
	1 to: 300 do: [:i | d at: (ByteArray new: i \\ 7 + 1) put: i].
	self assert: d size equals: 7.
	self assert: (d at: (ByteArray new: 3)) equals: 296.
	s := Set new.
	s add: #[1 2]; add: #[1 2] copy; add: 'ab'; add: #[97 98].
	self assert: s size equals: 3
]

{ #category : #tests }
ByteArrayTest >> testPastAChunk [
	"300 000 bytes, past the 256 KiB primitives 121 and 122 work in between two polls."
	| a b |
	a := ByteArray new: 300000.
	a at: 1 put: 9; at: 300000 put: 7.
	b := a copy.
	self assert: a = b.
	self assert: a hash equals: b hash.
	b at: 300000 put: 8.
	self deny: a = b.
	self deny: a hash = b hash.
	self deny: a = (a copyFrom: 1 to: 299999).
	self deny: (a copyFrom: 1 to: 299999) = a
]

{ #category : #tests }
ByteArrayTest >> testStringsNeverEqualByteArrays [
	| s b |
	s := 'ab'.
	b := #[97 98].
	self deny: s = b.
	self deny: b = s.
	self deny: b = #ab.
	self deny: #ab = b
]
