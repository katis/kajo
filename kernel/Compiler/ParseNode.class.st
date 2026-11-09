"A node of a method's tree (the Smalltalk compiler's)."
Class {
	#name : #ParseNode,
	#superclass : #Object,
	#instVars : [
		'line',
		'sourceStart',
		'sourceEnd'
	]
}

{ #category : #accessing }
ParseNode >> line [
	^ line
]

{ #category : #accessing }
ParseNode >> line: anInteger [
	line := anInteger
]

{ #category : #accessing }
ParseNode >> sourceEnd [
	"The end of the node's source range, a byte offset from 0, exclusive (module 9b: the source map's ranges, as the bootstrap compiler computes them)."
	^ sourceEnd
]

{ #category : #accessing }
ParseNode >> sourceStart [
	^ sourceStart
]

{ #category : #accessing }
ParseNode >> sourceStart: start end: end [
	sourceStart := start.
	sourceEnd := end
]
