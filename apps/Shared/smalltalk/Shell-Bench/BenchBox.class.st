"The share scenario's Box (module 7's sharestorm.kasm in Smalltalk): b = 7 a + 3, check answers 0 for an intact Box."
Class {
	#name : #BenchBox,
	#superclass : #Object,
	#instVars : [
		'a',
		'b',
		'next'
	]
}

{ #category : #building }
BenchBox class >> key: k prev: p [
	^ self basicNew setA: k b: 7 * k + 3 next: p
]

{ #category : #building }
BenchBox >> setA: x b: y next: n [
	a := x.
	b := y.
	next := n
]

{ #category : #building }
BenchBox >> next [
	^ next
]

{ #category : #building }
BenchBox >> check [
	^ b - (7 * a) - 3
]
