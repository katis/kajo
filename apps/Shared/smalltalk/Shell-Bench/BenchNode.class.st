"The storm's binary tree (module 7's allocstorm.kasm in Smalltalk)."
Class {
	#name : #BenchNode,
	#superclass : #Object,
	#instVars : [
		'left',
		'right'
	]
}

{ #category : #building }
BenchNode class >> build: depth [
	| n |
	n := self basicNew.
	depth > 0 ifTrue: [n setLeft: (self build: depth - 1) right: (self build: depth - 1)].
	^ n
]

{ #category : #building }
BenchNode >> setLeft: l right: r [
	left := l.
	right := r
]

{ #category : #building }
BenchNode >> check [
	left isNil ifTrue: [^ 1].
	^ left check + right check + 1
]
