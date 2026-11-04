"Methods MakeFuzzTest mutates and hands to the make-method primitive (module 8d): instance variables, blocks with copied values and temp vectors, a non-local return, literals of every kind, a class variable."
Class {
	#name : #MakeFuzzSample,
	#superclass : #Object,
	#instVars : [
		'a',
		'b'
	],
	#category : #'Kernel-Tests'
}

{ #category : #samples }
MakeFuzzSample >> classVariable [
	^ ClassVariableSample count
]

{ #category : #samples }
MakeFuzzSample >> closures: x [
	| t blocks |
	t := x.
	blocks := (1 to: 3) collect: [:i | [:k | t := t + i + k]].
	blocks do: [:blk | blk value: 1].
	^ t
]

{ #category : #samples }
MakeFuzzSample >> detect: x [
	#(1 5 9) do: [:e | e > x ifTrue: [^ e]].
	^ nil
]

{ #category : #samples }
MakeFuzzSample >> literals [
	^ {#(1 $a 'b' #c (2 3) #[1 2]). 1.5. 1.0e100. 123456789012345678901234567890. 'text'. #sym:with:. Object. b}
]

{ #category : #samples }
MakeFuzzSample >> loops: x [
	| k out |
	k := 0.
	out := OrderedCollection new.
	[k < x] whileTrue: [| u | k := k + 1. u := k. out add: [u := u * 2]].
	^ (out collect: [:blk | blk value]) inject: 0 into: [:p :q | p + q]
]

{ #category : #samples }
MakeFuzzSample >> sum: n [
	| s |
	s := 0.
	1 to: n do: [:i | s := s + (i * 2)].
	a := s.
	^ s
]
