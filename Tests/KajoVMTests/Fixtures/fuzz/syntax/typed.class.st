"Types 1: a class with its type parameters, its superclass type and typed instance variables."
Class {
	#name : #TypedFuzz,
	#superclass : #Object,
	#typeParameters : [
		'E',
		'K'
	],
	#superclassType : 'Object',
	#instVars : [
		'array <Array[E | Nil]>',
		'count <Integer>',
		'plain'
	]
}

{ #category : #accessing }
TypedFuzz >> at: index <Integer> ifAbsent: aBlock <[^:X]> ^<E | X> [
	^ (array at: index) ifNil: [aBlock value]
]

{ #category : #accessing }
TypedFuzz >> size ^<Integer>[
	^ count
]

{ #category : #accessing }
TypedFuzz >> inject: x <:A> into: aBlock <[A, E, ^A]> ^<A> [
	^ aBlock value: x value: array first
]
