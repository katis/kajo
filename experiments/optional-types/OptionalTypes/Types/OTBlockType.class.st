"A block taking args (types) and answering result: `[E, ^Boolean]`, `[^X]`. Arguments are contravariant and the result covariant."
Class {
	#name : #OTBlockType,
	#superclass : #OTType,
	#instVars : [
		'args',
		'result'
	]
}

{ #category : #accessing }
OTBlockType >> args [
	^ args
]

{ #category : #testing }
OTBlockType >> isBlockType [
	^ true
]

{ #category : #printing }
OTBlockType >> printOn: aStream [
	aStream nextPutAll: '['.
	args do: [:a | a printOn: aStream. aStream nextPutAll: ', '].
	aStream nextPutAll: '^'.
	result printOn: aStream.
	aStream nextPutAll: ']'
]

{ #category : #accessing }
OTBlockType >> result [
	^ result
]

{ #category : #comparing }
OTBlockType >> sameAs: aType [
	aType isBlockType ifFalse: [^ false].
	aType args size = args size ifFalse: [^ false].
	1 to: args size do: [:i | ((args at: i) sameAs: (aType args at: i)) ifFalse: [^ false]].
	^ result sameAs: aType result
]

{ #category : #accessing }
OTBlockType >> setArgs: anArray result: aType [
	args := anArray.
	result := aType
]

{ #category : #substitution }
OTBlockType >> substitute: aDictionary self: selfType instance: instanceType [
	^ OTBlockType args: (args collect: [:a | a substitute: aDictionary self: selfType instance: instanceType]) result: (result substitute: aDictionary self: selfType instance: instanceType)
]

{ #category : #substitution }
OTBlockType >> varsDo: aBlock [
	args do: [:a | a varsDo: aBlock].
	result varsDo: aBlock
]

{ #category : #'instance creation' }
OTBlockType class >> args: anArray result: aType [
	^ self new setArgs: anArray result: aType
]
