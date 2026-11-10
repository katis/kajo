"The read-only bit (ADR 0009 section 9): a refused store signals ModificationForbidden."
Class {
	#name : #ReadOnlyTest,
	#superclass : #TestCase
}

{ #category : #accessing }
ReadOnlyTest >> literalArray [
	^ #(1 2 3)
]

{ #category : #accessing }
ReadOnlyTest >> testAMethodsPartsStayReadOnly [
	"The review fixes, item 1: primitive 93 never clears the bit of what the VM pinned for good (a method's bytecodes, literal frame and literals, Symbols): slotAt: reaches them, and the interpreter trusts what it verified."
	| m |
	m := Object >> #printString.
	self should: [(m slotAt: 1) beWritable] raise: Error.
	self assert: (m slotAt: 1) isReadOnly.
	self should: [(m slotAt: 2) beWritable] raise: Error.
	self assert: (m slotAt: 2) isReadOnly.
	self should: [m bytecodes beWritable] raise: Error.
	self should: [#printString beWritable] raise: Error.
	self assert: #printString isReadOnly.
	self assert: 42 printString = '42'
]

{ #category : #accessing }
ReadOnlyTest >> testInstanceVariableStoreIntoReadOnly [
	| assoc r |
	assoc := 1 -> 2.
	assoc beReadOnly.
	r := [assoc value: 5. #stored] on: ModificationForbidden do: [:ex | ex resume: nil].
	self assert: r == #stored.
	self assert: assoc value = 2
]

{ #category : #accessing }
ReadOnlyTest >> testMethodLiteralsAreReadOnly [
	| lit |
	lit := self literalArray.
	self assert: lit isReadOnly.
	self should: [lit at: 1 put: 0] raise: ModificationForbidden.
	self assert: (lit at: 1) = 1.
	self assert: 'literal' isReadOnly.
	self assert: 3 isReadOnly
]

{ #category : #accessing }
ReadOnlyTest >> testStoresIntoReadOnlyObjectsSignal [
	| a e |
	a := Array new: 2.
	a beReadOnly.
	self assert: a isReadOnly.
	e := [a at: 1 put: 3. #stored] on: ModificationForbidden do: [:ex | ex].
	self assert: e class == ModificationForbidden.
	self assert: e object == a.
	self assert: e index = 1.
	self assert: e value = 3.
	self assert: (a at: 1) isNil.
	a beWritable.
	a at: 1 put: 3.
	self assert: (a at: 1) = 3
]
