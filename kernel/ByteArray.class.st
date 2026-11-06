"Bytes, indexed from 1; elements are SmallIntegers 0 to 255. The buffer a String WriteStream encodes into."
Class {
	#name : #ByteArray,
	#superclass : #ArrayedCollection,
	#category : #'Kernel-Collections',
	#type : #bytes
}

{ #category : #accessing }
ByteArray >> asString [
	^ self asStringValidating
]

{ #category : #accessing }
ByteArray >> asStringRepairing [
	"A String of these bytes, each ill-formed sequence replaced by U+FFFD."
	<primitive: 131>
	^ self primitiveFailed
]

{ #category : #accessing }
ByteArray >> asStringValidating [
	"A String of these bytes, refused unless they are UTF-8."
	<primitive: 130>
	^ self error: 'the bytes are not valid UTF-8'
]

{ #category : #accessing }
ByteArray >> encode: aCharacter at: offset [
	"Write the scalar's UTF-8 at offset; answer its byte count. Fails when it does not fit."
	<primitive: 128>
	^ nil
]

{ #category : #accessing }
ByteArray >> hash [
	| h |
	h := self size.
	self do: [:b | h := (h * 31 + b) bitAnd: 16r3FFFFFFF].
	^ h
]

{ #category : #accessing }
ByteArray >> isLiteral [
	^ true
]

{ #category : #accessing }
ByteArray >> printOn: aStream [
	aStream nextPutAll: '#['.
	self do: [:e | aStream print: e] separatedBy: [aStream space].
	aStream nextPut: $]
]

{ #category : #accessing }
ByteArray >> replaceFrom: start to: stop with: aCollection startingAt: from [
	"Large bytes: primitive 38 copies bytes from a byte object (polled between chunks past 256 KiB); anything else, or a copy within the receiver whose target overlaps after its source, runs the loop."
	<primitive: 38>
	^ super replaceFrom: start to: stop with: aCollection startingAt: from
]

{ #category : #accessing }
ByteArray >> utf8ScalarAt: i [
	"Decode the UTF-8 scalar starting at byte i (the bytes are known to be valid)."
	| b n v |
	b := self at: i.
	b < 16r80 ifTrue: [^ Character value: b].
	b < 16rE0 ifTrue: [n := 1. v := b bitAnd: 16r1F] ifFalse: [
		b < 16rF0 ifTrue: [n := 2. v := b bitAnd: 16r0F] ifFalse: [n := 3. v := b bitAnd: 16r07]].
	1 to: n do: [:k | v := (v bitShift: 6) bitOr: ((self at: i + k) bitAnd: 16r3F)].
	^ Character value: v
]
