"A WriteStream on a String that ends its printing at a limit and prints an object it is already printing as '...' (the review fixes, part 2, item 1: DevSession printOf:). When a put passes the limit it evaluates its limit block, which answers from the printing method; contents cuts what was written at the limit, on a scalar boundary. So a cyclic collection, or one of a million elements, answers a cut text and never overflows a stack or prints whole before it is cut."
Class {
	#name : #LimitedWriteStream,
	#superclass : #WriteStream,
	#instVars : [
		'limit',
		'limitBlock',
		'printing'
	]
}

{ #category : #accessing }
LimitedWriteStream >> checkLimit [
	position > limit ifTrue: [limitBlock value]
]

{ #category : #accessing }
LimitedWriteStream >> cutContents [
	"What was written, at most limit bytes, ending on a scalar boundary."
	| n |
	n := position min: limit.
	[n > 0 and: [n < position and: [((collection at: n + 1) bitAnd: 192) = 128]]] whileTrue: [n := n - 1].
	^ (collection copyFrom: 1 to: n) asStringValidating
]

{ #category : #accessing }
LimitedWriteStream >> isCut [
	^ position > limit
]

{ #category : #accessing }
LimitedWriteStream >> nextPut: anObject [
	super nextPut: anObject.
	self checkLimit.
	^ anObject
]

{ #category : #accessing }
LimitedWriteStream >> nextPutAll: aCollection [
	super nextPutAll: aCollection.
	self checkLimit.
	^ aCollection
]

{ #category : #accessing }
LimitedWriteStream >> print: anObject [
	"An object already being printed further out is '...': a collection that holds itself prints."
	(printing identityIncludes: anObject) ifTrue: [^ self nextPutAll: '...'].
	printing addLast: anObject.
	^ [anObject printOn: self] ensure: [printing removeLast]
]

{ #category : #accessing }
LimitedWriteStream >> setLimit: anInteger block: aBlock [
	limit := anInteger.
	limitBlock := aBlock.
	printing := OrderedCollection new
]

{ #category : #'instance creation' }
LimitedWriteStream class >> limit: anInteger onLimit: aBlock [
	"A stream on a new String that evaluates aBlock (which should answer from its home method) when more than anInteger bytes were written."
	^ (self on: String new) setLimit: anInteger block: aBlock
]
