"A block taking args (types) and answering result: `[E, ^Boolean]`, `[^X]`. Arguments are contravariant and the result covariant."
Class {
	#name : #BlockType,
	#superclass : #Type,
	#instVars : [
		'args',
		'result'
	]
}

{ #category : #accessing }
BlockType >> args [
	^ args
]

{ #category : #accessing }
BlockType >> result [
	^ result
]

{ #category : #accessing }
BlockType >> setArgs: anArray result: aType [
	args := anArray.
	result := aType
]

{ #category : #comparing }
BlockType >> sameAs: aType [
	aType isBlockType ifFalse: [^ false].
	aType args size = args size ifFalse: [^ false].
	1 to: args size do: [:i | ((args at: i) sameAs: (aType args at: i)) ifFalse: [^ false]].
	^ result sameAs: aType result
]

{ #category : #printing }
BlockType >> printOn: aStream [
	aStream nextPutAll: '['.
	args do: [:a | a printOn: aStream. aStream nextPutAll: ', '].
	aStream nextPutAll: '^'.
	result printOn: aStream.
	aStream nextPutAll: ']'
]

{ #category : #substitution }
BlockType >> substitute: aDictionary self: selfType instance: instanceType [
	^ BlockType args: (args collect: [:a | a substitute: aDictionary self: selfType instance: instanceType]) result: (result substitute: aDictionary self: selfType instance: instanceType)
]

{ #category : #substitution }
BlockType >> varsDo: aBlock [
	args do: [:a | a varsDo: aBlock].
	result varsDo: aBlock
]

{ #category : #testing }
BlockType >> isBlockType [
	^ true
]

{ #category : #'instance creation' }
BlockType class >> args: anArray result: aType [
	^ self new setArgs: anArray result: aType
]
